// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Low-level IMAP connection on SwiftNIO + swift-nio-imap + NIOSSL. Chosen over MailCore2 for a
// future-proof, SPM-native, Apple-maintained stack. Provides an async request/response primitive:
// send one tagged command, collect untagged responses until the tagged completion, return them.
//
// This is protocol-level plumbing; higher-level mail operations live in MailImapClient. The exact
// swift-nio-imap response shapes are hardened against the compiler in CI.

import Foundation
import NIO
import NIOSSL
import NIOIMAP
import NIOIMAPCore

/// A single IMAP command's collected responses.
struct IMAPCommandResult {
    let untagged: [Response]
    let completion: TaggedResponse
    var isOK: Bool {
        if case .ok = completion.state { return true }
        return false
    }
}

/// One IMAP connection to the server, driving swift-nio-imap's `IMAPClientHandler`.
actor MailNIOConnection {
    private let group: EventLoopGroup
    private let host: String
    private let port: Int
    private var channel: Channel?
    private var handler: CollectingIMAPHandler?
    private var tagCounter = 0

    init(host: String, port: Int = 993, group: EventLoopGroup) {
        self.host = host
        self.port = port
        self.group = group
    }

    func connect() async throws {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        let sslContext = try NIOSSLContext(configuration: tls)
        let host = self.host
        let collector = CollectingIMAPHandler()
        self.handler = collector

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                do {
                    let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    return channel.pipeline.addHandlers([
                        sslHandler,
                        IMAPClientHandler(),
                        collector
                    ])
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let channel = try await bootstrap.connect(host: host, port: port).get()
        self.channel = channel
        // Server greeting arrives as the first untagged response; wait for it.
        _ = try await collector.waitForGreeting()
    }

    /// Sends a tagged command and returns its collected responses.
    func send(_ command: Command) async throws -> IMAPCommandResult {
        guard let channel, let handler else { throw MailNIOError.notConnected }
        tagCounter += 1
        let tag = "A\(tagCounter)"
        let future = handler.expect(tag: tag)
        let part = CommandStreamPart.tagged(TaggedCommand(tag: tag, command: command))
        // swift-nio-imap 0.4's IMAPClientHandler expects Message.part(...) as
        // outbound type; writing a raw CommandStreamPart crashes at runtime.
        try await channel.writeAndFlush(IMAPClientHandler.Message.part(part)).get()
        return try await future.get()
    }

    func close() async {
        try? await channel?.close().get()
        channel = nil
    }

    enum MailNIOError: Error { case notConnected, timeout }
}

/// Collects untagged responses per pending tag and fulfils a promise on the tagged completion.
final class CollectingIMAPHandler: ChannelInboundHandler {
    typealias InboundIn = Response

    private var buffer: [Response] = []
    private var pending: [String: EventLoopPromise<IMAPCommandResult>] = [:]
    private var greeting: EventLoopPromise<Void>?
    private var eventLoop: EventLoop?

    func handlerAdded(context: ChannelHandlerContext) {
        eventLoop = context.eventLoop
    }

    func waitForGreeting() async throws {
        guard let eventLoop else { throw MailNIOConnection.MailNIOError.notConnected }
        let promise = eventLoop.makePromise(of: Void.self)
        greeting = promise
        try await promise.futureResult.get()
    }

    func expect(tag: String) -> EventLoopFuture<IMAPCommandResult> {
        let promise = eventLoop!.makePromise(of: IMAPCommandResult.self)
        pending[tag] = promise
        return promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        switch response {
        case .tagged(let tagged):
            let collected = buffer
            buffer.removeAll()
            if let promise = pending.removeValue(forKey: tagged.tag) {
                promise.succeed(IMAPCommandResult(untagged: collected, completion: tagged))
            }
        default:
            // Buffer every non-tagged response (untagged data + fetch stream) for the pending command.
            buffer.append(response)
            // The very first response is the server greeting.
            if let greeting { self.greeting = nil; greeting.succeed(()) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        greeting?.fail(error); greeting = nil
        pending.values.forEach { $0.fail(error) }
        pending.removeAll()
        context.close(promise: nil)
    }
}
