// SPDX-FileCopyrightText: 2026 Host-On Service Provider GmbH (Souvera)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Minimal SMTP client over SwiftNIO + NIOSSL. Implicit TLS on port 465 (the confirmed working
// Souvera/Stalwart SMTP port), AUTH LOGIN with the combined app-password. Line-based request/reply.
// Command/reply flow hardened against a live server in CI/on-device.

import Foundation
import NIO
import NIOSSL

actor MailSmtpClient {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let group: EventLoopGroup

    init(host: String, port: Int, username: String, password: String, group: EventLoopGroup) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.group = group
    }

    enum SmtpError: Error { case unexpectedReply(Int, String) }

    func send(from: String, recipients: [String], data: String) async throws {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        let sslContext = try NIOSSLContext(configuration: tls)
        let handler = SmtpResponseHandler()
        let host = self.host

        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                do {
                    let ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    return channel.pipeline.addHandlers([ssl, ByteToMessageHandler(LineBasedFrameDecoder()), handler])
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: host, port: port).get()
        defer { try? channel.close().wait() }

        func expect(_ ok: Int) async throws {
            let (code, text) = try await handler.next()
            guard code == ok else { throw SmtpError.unexpectedReply(code, text) }
        }
        func write(_ line: String) async throws {
            var buffer = channel.allocator.buffer(capacity: line.count + 2)
            buffer.writeString(line + "\r\n")
            try await channel.writeAndFlush(buffer).get()
        }

        try await expect(220)                                   // greeting
        try await write("EHLO souvera-ios"); try await expect(250)
        try await write("AUTH LOGIN"); try await expect(334)
        try await write(Data(username.utf8).base64EncodedString()); try await expect(334)
        try await write(Data(password.utf8).base64EncodedString()); try await expect(235)
        try await write("MAIL FROM:<\(from)>"); try await expect(250)
        for recipient in recipients where !recipient.isEmpty {
            try await write("RCPT TO:<\(recipient)>"); try await expect(250)
        }
        try await write("DATA"); try await expect(354)
        // Dot-stuffing: any line starting with '.' must be escaped.
        let escaped = data.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        try await write(escaped + "\r\n."); try await expect(250)
        try await write("QUIT")
    }
}

/// Parses SMTP reply lines ("250 OK", multi-line "250-..."), surfacing the final code+text.
private final class SmtpResponseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var pending: [(Int, String)] = []
    private var waiters: [CheckedContinuation<(Int, String), Error>] = []
    private var accumulated = ""

    func next() async throws -> (Int, String) {
        try await withCheckedThrowingContinuation { continuation in
            if !pending.isEmpty {
                continuation.resume(returning: pending.removeFirst())
            } else {
                waiters.append(continuation)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let line = buffer.readString(length: buffer.readableBytes) ?? ""
        // Continuation lines have a '-' after the 3-digit code; the last one has a space.
        let code = Int(line.prefix(3)) ?? 0
        if line.count > 3, line[line.index(line.startIndex, offsetBy: 3)] == "-" {
            accumulated += line + "\n"
            return
        }
        let full = accumulated + line
        accumulated = ""
        let value = (code, full)
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: value)
        } else {
            pending.append(value)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        waiters.forEach { $0.resume(throwing: error) }
        waiters.removeAll()
        context.close(promise: nil)
    }
}
