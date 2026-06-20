import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

enum WebDAVServerEvent {
    case started(Int)
    case stopped
    case failed(String)
    case request(String)
}

final class WebDAVServerManager {
    private enum State {
        case stopped
        case starting
        case running(Channel)
        case stopping
    }

    private let stateQueue = DispatchQueue(label: "local.pwebdav.server.state")
    private var state: State = .stopped
    private var group: MultiThreadedEventLoopGroup?
    private var threadPool: NIOThreadPool?
    private var pendingStop = false
    private var stopCompletions: [() -> Void] = []
    private let lockStore = WebDAVLockStore()

    func start(settings: AppSettings, settingsProvider: @escaping () -> AppSettings, eventSink: @escaping (WebDAVServerEvent) -> Void) {
        stateQueue.async {
            guard case .stopped = self.state else { return }
            self.state = .starting
            self.pendingStop = false

            let group = MultiThreadedEventLoopGroup(numberOfThreads: max(2, System.coreCount / 2))
            let threadPool = NIOThreadPool(numberOfThreads: 2)
            threadPool.start()
            let fileIO = NonBlockingFileIO(threadPool: threadPool)

            do {
                let sslContext = try Self.makeTLSContext(settings: settings)
                let bootstrap = ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.backlog, value: 256)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        let tlsFuture: EventLoopFuture<Void>
                        if let sslContext {
                            tlsFuture = channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext))
                        } else {
                            tlsFuture = channel.eventLoop.makeSucceededFuture(())
                        }

                        return tlsFuture.flatMap {
                            channel.pipeline.configureHTTPServerPipeline()
                        }.flatMap {
                            channel.pipeline.addHandler(WebDAVRequestHandler(
                                settingsProvider: settingsProvider,
                                eventSink: eventSink,
                                fileIO: fileIO,
                                lockStore: self.lockStore,
                                usesTLS: sslContext != nil
                            ))
                        }
                    }
                    .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

                self.group = group
                self.threadPool = threadPool

                bootstrap.bind(host: settings.bindAddress, port: settings.port).whenComplete { result in
                    self.stateQueue.async {
                        switch result {
                        case .success(let channel):
                            if self.pendingStop {
                                self.state = .stopping
                                channel.close(promise: nil)
                            } else {
                                self.state = .running(channel)
                                eventSink(.started(settings.port))
                            }

                            channel.closeFuture.whenComplete { _ in
                                self.stateQueue.async {
                                    self.finishStopped(eventSink: eventSink)
                                }
                            }
                        case .failure(let error):
                            self.finishStopped(eventSink: nil)
                            eventSink(.failed(error.localizedDescription))
                        }
                    }
                }
            } catch {
                self.group = group
                self.threadPool = threadPool
                self.finishStopped(eventSink: nil)
                eventSink(.failed(error.localizedDescription))
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        stateQueue.async {
            if let completion {
                self.stopCompletions.append(completion)
            }

            switch self.state {
            case .stopped:
                self.runStopCompletions()
            case .starting:
                self.pendingStop = true
            case .running(let channel):
                self.state = .stopping
                channel.close(promise: nil)
            case .stopping:
                break
            }
        }
    }

    private func finishStopped(eventSink: ((WebDAVServerEvent) -> Void)?) {
        guard !isStoppedState else {
            runStopCompletions()
            return
        }

        let group = self.group
        let threadPool = self.threadPool
        self.group = nil
        self.threadPool = nil
        self.pendingStop = false
        self.state = .stopped
        self.lockStore.removeAll()
        eventSink?(.stopped)

        DispatchQueue.global(qos: .utility).async {
            try? group?.syncShutdownGracefully()
            try? threadPool?.syncShutdownGracefully()
        }
        runStopCompletions()
    }

    private var isStoppedState: Bool {
        if case .stopped = state { return true }
        return false
    }

    private func runStopCompletions() {
        let completions = stopCompletions
        stopCompletions.removeAll()
        completions.forEach { $0() }
    }

    private static func makeTLSContext(settings: AppSettings) throws -> NIOSSLContext? {
        guard settings.tlsEnabled else { return nil }

        let certificatePath = settings.tlsCertificatePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKeyPath = settings.tlsPrivateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !certificatePath.isEmpty, !privateKeyPath.isEmpty else {
            throw WebDAVError.tlsConfiguration("TLS certificate and private key are required.")
        }

        let certificates = try NIOSSLCertificate.fromPEMFile(certificatePath).map {
            NIOSSLCertificateSource.certificate($0)
        }
        let privateKey = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem)
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates,
            privateKey: .privateKey(privateKey)
        )
        return try NIOSSLContext(configuration: configuration)
    }
}

private final class WebDAVRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let settingsProvider: () -> AppSettings
    private let eventSink: (WebDAVServerEvent) -> Void
    private let fileIO: NonBlockingFileIO
    private let lockStore: WebDAVLockStore
    private let usesTLS: Bool
    private var currentRequest: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private var shouldDiscardBody = false
    private var uploadState: UploadState?

    init(
        settingsProvider: @escaping () -> AppSettings,
        eventSink: @escaping (WebDAVServerEvent) -> Void,
        fileIO: NonBlockingFileIO,
        lockStore: WebDAVLockStore,
        usesTLS: Bool
    ) {
        self.settingsProvider = settingsProvider
        self.eventSink = eventSink
        self.fileIO = fileIO
        self.lockStore = lockStore
        self.usesTLS = usesTLS
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            shouldDiscardBody = false
            let settings = settingsProvider()
            if requestExceedsUploadLimit(head, settings: settings) {
                respond(status: HTTPResponseStatus(statusCode: 413, reasonPhrase: "Payload Too Large"), context: context, keepAlive: head.isKeepAlive)
                currentRequest = nil
                bodyBuffer = nil
                shouldDiscardBody = true
            } else if head.method == .PUT {
                currentRequest = head
                beginStreamingPut(request: head, settings: settings, context: context)
            } else {
                currentRequest = head
                bodyBuffer = context.channel.allocator.buffer(capacity: 0)
            }
        case .body(var body):
            guard !shouldDiscardBody else { return }
            if uploadState != nil {
                streamUploadBody(&body, context: context)
            } else {
                bodyBuffer?.writeBuffer(&body)
                let settings = settingsProvider()
                if let readableBytes = bodyBuffer?.readableBytes, requestBodyExceedsLimit(readableBytes, settings: settings) {
                    respond(status: HTTPResponseStatus(statusCode: 413, reasonPhrase: "Payload Too Large"), context: context, keepAlive: currentRequest?.isKeepAlive ?? false)
                    currentRequest = nil
                    bodyBuffer = nil
                    shouldDiscardBody = true
                }
            }
        case .end:
            guard !shouldDiscardBody else {
                shouldDiscardBody = false
                return
            }
            if uploadState != nil {
                finishStreamingPut(context: context)
                currentRequest = nil
                return
            }
            guard let request = currentRequest else { return }
            handle(request: request, body: bodyBuffer, context: context)
            currentRequest = nil
            bodyBuffer = nil
        }
    }

    private func beginStreamingPut(request: HTTPRequestHead, settings: AppSettings, context: ChannelHandlerContext) {
        let route = Route(uri: request.uri, settings: settings)
        eventSink(.request("\(request.method.rawValue) \(route.logPath)"))
        let auth = AuthContext(request: request, settings: settings, shareID: route.share?.id)
        let clientKey = context.channel.remoteAddress.map(String.init(describing:)) ?? "unknown"

        do {
            guard !AuthRateLimiter.shared.isLimited(clientKey) else {
                throw WebDAVError.tooManyRequests
            }
            guard auth.hasEnabledAccounts else {
                throw WebDAVError.forbidden
            }
            guard auth.isAllowed else {
                AuthRateLimiter.shared.recordFailure(for: clientKey)
                respondUnauthorized(context: context, keepAlive: request.isKeepAlive)
                shouldDiscardBody = true
                return
            }
            AuthRateLimiter.shared.recordSuccess(for: clientKey)

            try validateRoute(route)
            guard auth.canWrite else { throw WebDAVError.forbidden }
            try validateWriteLock(route: route, request: request)
            guard let url = route.fileURL, let share = route.share else { throw WebDAVError.forbidden }

            let parent = url.deletingLastPathComponent()
            var parentIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else { throw WebDAVError.conflict }
            try validateInsideShare(parent, share: share)
            if FileManager.default.fileExists(atPath: url.path) {
                try validateInsideShare(url, share: share)
            }

            let existed = FileManager.default.fileExists(atPath: url.path)
            let handle = try NIOFileHandle(
                _deprecatedPath: url.path,
                mode: .write,
                flags: .posix(flags: O_CREAT | O_TRUNC, mode: NIOFileHandle.Flags.defaultPermissions)
            )
            uploadState = UploadState(
                request: request,
                route: route,
                fileHandle: handle,
                existed: existed,
                bytesReceived: 0,
                nextOffset: 0,
                writeFuture: context.eventLoop.makeSucceededFuture(())
            )
        } catch WebDAVError.tooManyRequests {
            respond(status: HTTPResponseStatus(statusCode: 429, reasonPhrase: "Too Many Requests"), context: context, keepAlive: request.isKeepAlive)
            shouldDiscardBody = true
        } catch WebDAVError.notFound {
            respond(status: .notFound, context: context, keepAlive: request.isKeepAlive)
            shouldDiscardBody = true
        } catch WebDAVError.forbidden {
            respond(status: .forbidden, context: context, keepAlive: request.isKeepAlive)
            shouldDiscardBody = true
        } catch WebDAVError.conflict {
            respond(status: .conflict, context: context, keepAlive: request.isKeepAlive)
            shouldDiscardBody = true
        } catch WebDAVError.locked {
            respond(status: HTTPResponseStatus(statusCode: 423, reasonPhrase: "Locked"), context: context, keepAlive: request.isKeepAlive)
            shouldDiscardBody = true
        } catch {
            eventSink(.request("ERROR PUT \(route.logPath): \(error.localizedDescription)"))
            respond(status: .internalServerError, context: context, keepAlive: request.isKeepAlive)
            shouldDiscardBody = true
        }
    }

    private func streamUploadBody(_ body: inout ByteBuffer, context: ChannelHandlerContext) {
        guard var state = uploadState else { return }
        let bytes = body.readableBytes
        let settings = settingsProvider()
        let nextByteCount = state.bytesReceived + bytes
        if requestBodyExceedsLimit(nextByteCount, settings: settings) {
            try? state.fileHandle.close()
            if !state.existed, let url = state.route.fileURL {
                try? FileManager.default.removeItem(at: url)
            }
            uploadState = nil
            currentRequest = nil
            shouldDiscardBody = true
            respond(status: HTTPResponseStatus(statusCode: 413, reasonPhrase: "Payload Too Large"), context: context, keepAlive: state.request.isKeepAlive)
            return
        }

        let offset = state.nextOffset
        let chunk = body
        let fileHandle = state.fileHandle
        state.bytesReceived = nextByteCount
        state.nextOffset += Int64(bytes)
        state.writeFuture = state.writeFuture.flatMap { [fileIO] in
            fileIO.write(fileHandle: fileHandle, toOffset: offset, buffer: chunk, eventLoop: context.eventLoop)
        }
        uploadState = state
    }

    private func finishStreamingPut(context: ChannelHandlerContext) {
        guard let state = uploadState else { return }
        uploadState = nil

        state.writeFuture.whenComplete { result in
            try? state.fileHandle.close()
            switch result {
            case .success:
                self.respond(status: state.existed ? .noContent : .created, context: context, keepAlive: state.request.isKeepAlive)
            case .failure(let error):
                self.eventSink(.request("ERROR PUT \(state.route.logPath): \(error.localizedDescription)"))
                self.respond(status: .internalServerError, context: context, keepAlive: state.request.isKeepAlive)
            }
        }
    }

    private func requestExceedsUploadLimit(_ request: HTTPRequestHead, settings: AppSettings) -> Bool {
        guard let contentLength = request.headers.first(name: "Content-Length"),
              let byteCount = Int64(contentLength) else {
            return false
        }
        return requestBodyExceedsLimit(byteCount, settings: settings)
    }

    private func requestBodyExceedsLimit(_ byteCount: Int, settings: AppSettings) -> Bool {
        requestBodyExceedsLimit(Int64(byteCount), settings: settings)
    }

    private func requestBodyExceedsLimit(_ byteCount: Int64, settings: AppSettings) -> Bool {
        guard settings.uploadLimitEnabled else { return false }
        let megabytes = max(1, settings.uploadLimitMB)
        return byteCount > Int64(megabytes) * 1024 * 1024
    }

    private func handle(request: HTTPRequestHead, body: ByteBuffer?, context: ChannelHandlerContext) {
        let method = request.method.rawValue

        let settings = settingsProvider()
        let route = Route(uri: request.uri, settings: settings)
        eventSink(.request("\(method) \(route.logPath)"))
        let auth = AuthContext(request: request, settings: settings, shareID: route.share?.id)
        let clientKey = context.channel.remoteAddress.map(String.init(describing:)) ?? "unknown"

        guard !AuthRateLimiter.shared.isLimited(clientKey) else {
            respond(status: HTTPResponseStatus(statusCode: 429, reasonPhrase: "Too Many Requests"), context: context, keepAlive: request.isKeepAlive)
            return
        }

        guard auth.hasEnabledAccounts else {
            respond(status: .forbidden, context: context, keepAlive: request.isKeepAlive)
            return
        }

        guard auth.isAllowed else {
            AuthRateLimiter.shared.recordFailure(for: clientKey)
            respondUnauthorized(context: context, keepAlive: request.isKeepAlive)
            return
        }
        AuthRateLimiter.shared.recordSuccess(for: clientKey)

        do {
            try validateRoute(route)
            switch request.method {
            case .OPTIONS:
                respondOptions(context: context, keepAlive: request.isKeepAlive)
            case .GET:
                guard auth.canRead else { throw WebDAVError.forbidden }
                try respondGet(route: route, auth: auth, settings: settings, context: context, keepAlive: request.isKeepAlive, includeBody: true)
            case .HEAD:
                guard auth.canRead else { throw WebDAVError.forbidden }
                try respondGet(route: route, auth: auth, settings: settings, context: context, keepAlive: request.isKeepAlive, includeBody: false)
            case .PUT:
                guard auth.canWrite else { throw WebDAVError.forbidden }
                try validateWriteLock(route: route, request: request)
                try handlePut(route: route, body: body, context: context, keepAlive: request.isKeepAlive)
            case .DELETE:
                guard auth.canWrite else { throw WebDAVError.forbidden }
                try validateWriteLock(route: route, request: request)
                try handleDelete(route: route, context: context, keepAlive: request.isKeepAlive)
            case .MKCOL:
                guard auth.canWrite else { throw WebDAVError.forbidden }
                try validateWriteLock(route: route, request: request)
                try handleMkcol(route: route, context: context, keepAlive: request.isKeepAlive)
            case .PROPFIND:
                guard auth.canRead else { throw WebDAVError.forbidden }
                try handlePropfind(route: route, auth: auth, settings: settings, request: request, context: context, keepAlive: request.isKeepAlive)
            case .MOVE:
                guard auth.canWrite else { throw WebDAVError.forbidden }
                try validateWriteLock(route: route, request: request)
                try handleMove(route: route, settings: settings, request: request, context: context, keepAlive: request.isKeepAlive)
            case .COPY:
                guard auth.canWrite else { throw WebDAVError.forbidden }
                try handleCopy(route: route, settings: settings, request: request, context: context, keepAlive: request.isKeepAlive)
            case .LOCK:
                guard auth.canWrite else { throw WebDAVError.forbidden }
                try handleLock(route: route, request: request, body: body, context: context, keepAlive: request.isKeepAlive)
            case .UNLOCK:
                guard auth.canWrite else { throw WebDAVError.forbidden }
                try handleUnlock(route: route, request: request, context: context, keepAlive: request.isKeepAlive)
            default:
                respond(status: .methodNotAllowed, context: context, keepAlive: request.isKeepAlive)
            }
        } catch WebDAVError.notFound {
            respond(status: .notFound, context: context, keepAlive: request.isKeepAlive)
        } catch WebDAVError.forbidden {
            respond(status: .forbidden, context: context, keepAlive: request.isKeepAlive)
        } catch WebDAVError.conflict {
            respond(status: .conflict, context: context, keepAlive: request.isKeepAlive)
        } catch WebDAVError.preconditionFailed {
            respond(status: .preconditionFailed, context: context, keepAlive: request.isKeepAlive)
        } catch WebDAVError.locked {
            respond(status: HTTPResponseStatus(statusCode: 423, reasonPhrase: "Locked"), context: context, keepAlive: request.isKeepAlive)
        } catch WebDAVError.badRequest {
            respond(status: .badRequest, context: context, keepAlive: request.isKeepAlive)
        } catch WebDAVError.tooManyRequests {
            respond(status: HTTPResponseStatus(statusCode: 429, reasonPhrase: "Too Many Requests"), context: context, keepAlive: request.isKeepAlive)
        } catch {
            eventSink(.request("ERROR \(method) \(route.logPath): \(error.localizedDescription)"))
            respond(status: .internalServerError, context: context, keepAlive: request.isKeepAlive)
        }
    }

    private func respondOptions(context: ChannelHandlerContext, keepAlive: Bool) {
        var headers = HTTPHeaders()
        headers.add(name: "DAV", value: "1,2")
        headers.add(name: "Allow", value: "OPTIONS, PROPFIND, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, LOCK, UNLOCK")
        headers.add(name: "MS-Author-Via", value: "DAV")
        respond(status: .ok, headers: headers, context: context, keepAlive: keepAlive)
    }

    private func respondGet(route: Route, auth: AuthContext, settings: AppSettings, context: ChannelHandlerContext, keepAlive: Bool, includeBody: Bool) throws {
        if route.isRoot {
            respondHTML(directoryHTML(entries: rootEntries(settings: settings, auth: auth), title: "PWebDAV", path: "/"), context: context, keepAlive: keepAlive, includeBody: includeBody)
            return
        }

        guard let url = route.fileURL, let share = route.share else { throw WebDAVError.notFound }
        guard FileManager.default.fileExists(atPath: url.path) else { throw WebDAVError.notFound }
        try validateInsideShare(url, share: share)

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let entries = try fileEntries(route: route, url: url, depth: "1")
            let directoryHref = route.href.hasSuffix("/") ? route.href : route.href + "/"
            respondHTML(directoryHTML(entries: entries, title: directoryHref, path: directoryHref), context: context, keepAlive: keepAlive, includeBody: includeBody)
            return
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? NSNumber
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(fileSize?.int64Value ?? 0)")
        headers.add(name: "Content-Type", value: mimeType(for: url))

        var responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        addSecurityHeaders(to: &responseHead.headers)
        if keepAlive {
            responseHead.headers.add(name: "Connection", value: "keep-alive")
        }

        guard includeBody else {
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            finish(context: context, keepAlive: keepAlive)
            return
        }

        let opened = fileIO.openFile(_deprecatedPath: url.path, eventLoop: context.eventLoop)
        opened.whenComplete { result in
            switch result {
            case .success(let fileAndRegion):
                let fileHandle = fileAndRegion.0
                let fileRegion = fileAndRegion.1
                context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)

                let writeFuture: EventLoopFuture<Void>
                if self.usesTLS {
                    writeFuture = self.fileIO.readChunked(
                        fileRegion: fileRegion,
                        allocator: context.channel.allocator,
                        eventLoop: context.eventLoop
                    ) { buffer in
                        context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))))
                    }
                } else {
                    writeFuture = context.writeAndFlush(self.wrapOutboundOut(.body(.fileRegion(fileRegion))))
                }

                writeFuture.flatMap {
                    self.finishFuture(context: context, keepAlive: keepAlive)
                }.whenComplete { _ in
                    try? fileHandle.close()
                }
            case .failure(let error):
                self.eventSink(.request("ERROR GET \(route.logPath): \(error.localizedDescription)"))
                self.respond(status: .internalServerError, context: context, keepAlive: keepAlive)
            }
        }
    }

    private func handlePut(route: Route, body: ByteBuffer?, context: ChannelHandlerContext, keepAlive: Bool) throws {
        guard let url = route.fileURL, let share = route.share else { throw WebDAVError.forbidden }
        let parent = url.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else { throw WebDAVError.conflict }
        try validateInsideShare(parent, share: share)
        if FileManager.default.fileExists(atPath: url.path) {
            try validateInsideShare(url, share: share)
        }

        var buffer = body ?? context.channel.allocator.buffer(capacity: 0)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let data = Data(bytes)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try data.write(to: url, options: Data.WritingOptions.atomic)
        respond(status: existed ? .noContent : .created, context: context, keepAlive: keepAlive)
    }

    private func handleDelete(route: Route, context: ChannelHandlerContext, keepAlive: Bool) throws {
        guard let url = route.fileURL, let share = route.share else { throw WebDAVError.forbidden }
        guard FileManager.default.fileExists(atPath: url.path) else { throw WebDAVError.notFound }
        try validateInsideShare(url, share: share)
        try FileManager.default.removeItem(at: url)
        respond(status: .noContent, context: context, keepAlive: keepAlive)
    }

    private func handleMkcol(route: Route, context: ChannelHandlerContext, keepAlive: Bool) throws {
        guard let url = route.fileURL, let share = route.share else { throw WebDAVError.forbidden }
        let parent = url.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else { throw WebDAVError.conflict }
        try validateInsideShare(parent, share: share)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw WebDAVError.conflict }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        respond(status: .created, context: context, keepAlive: keepAlive)
    }

    private func handleMove(route: Route, settings: AppSettings, request: HTTPRequestHead, context: ChannelHandlerContext, keepAlive: Bool) throws {
        try handleCopyMove(route: route, settings: settings, request: request, context: context, keepAlive: keepAlive, shouldMove: true)
    }

    private func handleCopy(route: Route, settings: AppSettings, request: HTTPRequestHead, context: ChannelHandlerContext, keepAlive: Bool) throws {
        try handleCopyMove(route: route, settings: settings, request: request, context: context, keepAlive: keepAlive, shouldMove: false)
    }

    private func handleCopyMove(route: Route, settings: AppSettings, request: HTTPRequestHead, context: ChannelHandlerContext, keepAlive: Bool, shouldMove: Bool) throws {
        guard let sourceURL = route.fileURL, let sourceShare = route.share else { throw WebDAVError.forbidden }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw WebDAVError.notFound }
        try validateInsideShare(sourceURL, share: sourceShare)
        guard let destination = request.headers.first(name: "Destination") else { throw WebDAVError.conflict }

        let destinationURI = URL(string: destination)?.path ?? destination
        let destinationRoute = Route(uri: destinationURI, settings: settings)
        try validateRoute(destinationRoute)
        try validateWriteLock(route: destinationRoute, request: request)
        let destinationAuth = AuthContext(request: request, settings: settings, shareID: destinationRoute.share?.id)
        guard destinationAuth.canWrite, let targetURL = destinationRoute.fileURL, let targetShare = destinationRoute.share else { throw WebDAVError.forbidden }

        let parent = targetURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else { throw WebDAVError.conflict }
        try validateInsideShare(parent, share: targetShare)

        if FileManager.default.fileExists(atPath: targetURL.path) {
            try validateInsideShare(targetURL, share: targetShare)
            if request.headers.first(name: "Overwrite")?.uppercased() == "F" {
                throw WebDAVError.preconditionFailed
            }
            try FileManager.default.removeItem(at: targetURL)
        }

        if shouldMove {
            try FileManager.default.moveItem(at: sourceURL, to: targetURL)
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        }
        respond(status: .created, context: context, keepAlive: keepAlive)
    }

    private func handleLock(route: Route, request: HTTPRequestHead, body: ByteBuffer?, context: ChannelHandlerContext, keepAlive: Bool) throws {
        guard route.share != nil else { throw WebDAVError.forbidden }
        let timeout = lockTimeout(from: request.headers.first(name: "Timeout"))
        let owner = lockOwner(from: body)
        let providedTokens = lockTokens(from: request)

        if let refreshed = lockStore.refresh(path: route.href, tokens: providedTokens, timeout: timeout) {
            respondLock(refreshed, context: context, keepAlive: keepAlive)
            return
        }

        guard lockStore.canWrite(path: route.href, providedTokens: providedTokens) else {
            throw WebDAVError.locked
        }

        let lock = lockStore.create(path: route.href, depth: request.headers.first(name: "Depth") ?? "infinity", timeout: timeout, owner: owner)
        respondLock(lock, context: context, keepAlive: keepAlive)
    }

    private func handleUnlock(route: Route, request: HTTPRequestHead, context: ChannelHandlerContext, keepAlive: Bool) throws {
        guard route.share != nil else { throw WebDAVError.forbidden }
        guard let token = request.headers.first(name: "Lock-Token").flatMap(WebDAVLockStore.normalizedToken) else {
            throw WebDAVError.badRequest
        }
        guard lockStore.unlock(path: route.href, token: token) else {
            throw WebDAVError.conflict
        }
        respond(status: .noContent, context: context, keepAlive: keepAlive)
    }

    private func respondLock(_ lock: WebDAVLock, context: ChannelHandlerContext, keepAlive: Bool) {
        let xml = lockDiscoveryXML([lock])
        let data = Data(xml.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/xml; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Lock-Token", value: "<\(lock.token)>")
        respond(status: .ok, headers: headers, body: data, context: context, keepAlive: keepAlive)
    }

    private func handlePropfind(route: Route, auth: AuthContext, settings: AppSettings, request: HTTPRequestHead?, context: ChannelHandlerContext, keepAlive: Bool) throws {
        let depth = request?.headers.first(name: "Depth") ?? "1"
        let entries: [PropfindEntry]

        if route.isRoot {
            entries = rootEntries(settings: settings, auth: auth)
        } else {
            guard let url = route.fileURL, let share = route.share, FileManager.default.fileExists(atPath: url.path) else { throw WebDAVError.notFound }
            try validateInsideShare(url, share: share)
            entries = try fileEntries(route: route, url: url, depth: depth)
        }

        let xml = propfindXML(entries: entries)
        let data = Data(xml.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/xml; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(data.count)")
        respond(status: HTTPResponseStatus(statusCode: 207, reasonPhrase: "Multi-Status"), headers: headers, body: data, context: context, keepAlive: keepAlive)
    }

    private func respondHTML(_ html: String, context: ChannelHandlerContext, keepAlive: Bool, includeBody: Bool) {
        let data = Data(html.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(data.count)")
        respond(status: .ok, headers: headers, body: includeBody ? data : nil, context: context, keepAlive: keepAlive)
    }

    private func rootEntries(settings: AppSettings, auth: AuthContext) -> [PropfindEntry] {
        let root = PropfindEntry(href: "/", isDirectory: true, size: nil, modified: Date())
        let shares = settings.shares
            .filter(\.enabled)
            .filter { share in auth.permission(for: share.id).canRead }
            .map { share in
                PropfindEntry(href: "/\(share.virtualName.urlPathEscaped)/", isDirectory: true, size: nil, modified: modifiedDate(URL(fileURLWithPath: share.localPath)))
            }
        return [root] + shares
    }

    private func fileEntries(route: Route, url: URL, depth: String) throws -> [PropfindEntry] {
        let base = try propfindEntry(url: url, href: route.href)
        guard depth != "0" else { return [base] }
        guard let share = route.share else { return [base] }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else { return [base] }

        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: share.protectHiddenFiles ? [.skipsHiddenFiles] : []
        )
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .compactMap { child -> PropfindEntry? in
            guard (try? validateInsideShare(child, share: share)) != nil else { return nil }
            let childHref = route.href.hasSuffix("/")
                ? route.href + child.lastPathComponent.urlPathEscaped
                : route.href + "/" + child.lastPathComponent.urlPathEscaped
            return try propfindEntry(url: child, href: childHref)
        }

        return [base] + children
    }

    private func propfindEntry(url: URL, href: String) throws -> PropfindEntry {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDirectory = values.isDirectory ?? false
        let normalizedHref = isDirectory && !href.hasSuffix("/") ? href + "/" : href
        return PropfindEntry(
            href: normalizedHref,
            isDirectory: isDirectory,
            size: isDirectory ? nil : values.fileSize,
            modified: values.contentModificationDate ?? Date()
        )
    }

    private func respondUnauthorized(context: ChannelHandlerContext, keepAlive: Bool) {
        var headers = HTTPHeaders()
        headers.add(name: "WWW-Authenticate", value: #"Basic realm="PWebDAV""#)
        respond(status: .unauthorized, headers: headers, context: context, keepAlive: keepAlive)
    }

    private func validateRoute(_ route: Route) throws {
        if route.invalidPath || route.isHiddenProtected {
            throw WebDAVError.notFound
        }
    }

    private func validateWriteLock(route: Route, request: HTTPRequestHead) throws {
        guard route.share != nil else { return }
        guard lockStore.canWrite(path: route.href, providedTokens: lockTokens(from: request)) else {
            throw WebDAVError.locked
        }
    }

    private func validateInsideShare(_ url: URL, share: ShareDirectory) throws {
        let basePath = canonicalPath(URL(fileURLWithPath: share.localPath))
        let targetPath = canonicalPath(url)
        guard targetPath == basePath || targetPath.hasPrefix(basePath + "/") else {
            throw WebDAVError.forbidden
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private func lockTokens(from request: HTTPRequestHead) -> Set<String> {
        var tokens = Set<String>()
        if let lockToken = request.headers.first(name: "Lock-Token"),
           let normalized = WebDAVLockStore.normalizedToken(lockToken) {
            tokens.insert(normalized)
        }

        if let ifHeader = request.headers.first(name: "If") {
            for token in WebDAVLockStore.tokens(in: ifHeader) {
                tokens.insert(token)
            }
        }
        return tokens
    }

    private func lockTimeout(from header: String?) -> TimeInterval {
        guard let header else { return 3600 }
        let parts = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for part in parts {
            if part.lowercased().hasPrefix("second-"),
               let seconds = TimeInterval(part.dropFirst("Second-".count)) {
                return min(max(seconds, 60), 86_400)
            }
        }
        return 3600
    }

    private func lockOwner(from body: ByteBuffer?) -> String? {
        guard var body, let data = body.readString(length: body.readableBytes), !data.isEmpty else {
            return nil
        }
        return data
    }

    private func respond(
        status: HTTPResponseStatus,
        headers: HTTPHeaders = HTTPHeaders(),
        body: Data? = nil,
        context: ChannelHandlerContext,
        keepAlive: Bool
    ) {
        var headers = headers
        if let body, headers.first(name: "Content-Length") == nil {
            headers.add(name: "Content-Length", value: "\(body.count)")
        } else if body == nil, headers.first(name: "Content-Length") == nil {
            headers.add(name: "Content-Length", value: "0")
        }
        if keepAlive {
            headers.add(name: "Connection", value: "keep-alive")
        }
        addSecurityHeaders(to: &headers)

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let body {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        finish(context: context, keepAlive: keepAlive)
    }

    private func finish(context: ChannelHandlerContext, keepAlive: Bool) {
        _ = finishFuture(context: context, keepAlive: keepAlive)
    }

    private func finishFuture(context: ChannelHandlerContext, keepAlive: Bool) -> EventLoopFuture<Void> {
        let promise = keepAlive ? nil : context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        promise?.futureResult.whenComplete { _ in
            context.close(promise: nil)
        }
        return promise?.futureResult ?? context.eventLoop.makeSucceededFuture(())
    }

    private func modifiedDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? Date()
    }

    private func propfindXML(entries: [PropfindEntry]) -> String {
        let responses = entries.map { entry in
            let resourceType = entry.isDirectory ? "<D:collection/>" : ""
            let contentLength = entry.size.map { "<D:getcontentlength>\($0)</D:getcontentlength>" } ?? ""
            let locks = lockDiscoveryXMLFragment(lockStore.locks(for: entry.href))
            return """
            <D:response>
              <D:href>\(entry.href.xmlEscaped)</D:href>
              <D:propstat>
                <D:prop>
                  <D:resourcetype>\(resourceType)</D:resourcetype>
                  \(contentLength)
                  <D:getlastmodified>\(Self.httpDateFormatter.string(from: entry.modified))</D:getlastmodified>
                  \(locks)
                </D:prop>
                <D:status>HTTP/1.1 200 OK</D:status>
              </D:propstat>
            </D:response>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(responses)
        </D:multistatus>
        """
    }

    private func lockDiscoveryXML(_ locks: [WebDAVLock]) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:">
          \(lockDiscoveryXMLFragment(locks))
        </D:prop>
        """
    }

    private func lockDiscoveryXMLFragment(_ locks: [WebDAVLock]) -> String {
        let activeLocks = locks.map { lock in
            """
            <D:activelock>
              <D:lockscope><D:exclusive/></D:lockscope>
              <D:locktype><D:write/></D:locktype>
              <D:depth>\(lock.depth.xmlEscaped)</D:depth>
              <D:owner>\((lock.owner ?? "PWebDAV").xmlEscaped)</D:owner>
              <D:timeout>Second-\(max(0, Int(lock.expiresAt.timeIntervalSinceNow)))</D:timeout>
              <D:locktoken><D:href>\(lock.token.xmlEscaped)</D:href></D:locktoken>
              <D:lockroot><D:href>\(lock.path.xmlEscaped)</D:href></D:lockroot>
            </D:activelock>
            """
        }.joined(separator: "\n")
        return "<D:lockdiscovery>\(activeLocks)</D:lockdiscovery>"
    }

    private func directoryHTML(entries: [PropfindEntry], title: String, path: String) -> String {
        let parentRow: String
        if path != "/" {
            parentRow = """
                <tr>
                  <td><a href="\(parentHref(for: path).htmlEscaped)">../</a></td>
                  <td>-</td>
                  <td>-</td>
                </tr>
            """
        } else {
            parentRow = ""
        }

        let rows = entries
            .filter { !sameHref($0.href, path) }
            .map { entry in
                let displayName: String
                if entry.href == "/" {
                    displayName = "/"
                } else {
                    let trimmed = entry.href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    displayName = trimmed.split(separator: "/").last.map(String.init) ?? entry.href
                }

                let suffix = entry.isDirectory && displayName != "/" ? "/" : ""
                let size = entry.isDirectory ? "-" : ByteCountFormatter.string(fromByteCount: Int64(entry.size ?? 0), countStyle: .file)
                let modified = Self.httpDateFormatter.string(from: entry.modified)

                return """
                <tr>
                  <td><a href="\(entry.href.htmlEscaped)">\(displayName.removingPercentEncoding?.htmlEscaped ?? displayName.htmlEscaped)\(suffix)</a></td>
                  <td>\(size.htmlEscaped)</td>
                  <td>\(modified.htmlEscaped)</td>
                </tr>
                """
            }
            .joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title.htmlEscaped)</title>
          <style>
            body { font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 32px; color: #1f2328; }
            h1 { font-size: 22px; margin: 0 0 18px; }
            table { width: 100%; border-collapse: collapse; }
            th, td { border-bottom: 1px solid #d8dee4; padding: 9px 8px; text-align: left; }
            th { color: #57606a; font-weight: 600; }
            a { color: #0969da; text-decoration: none; }
            a:hover { text-decoration: underline; }
          </style>
        </head>
        <body>
          <h1>PWebDAV \(path.htmlEscaped)</h1>
          <table>
            <thead><tr><th>\(L.str("web.name").htmlEscaped)</th><th>\(L.str("web.size").htmlEscaped)</th><th>\(L.str("web.modified").htmlEscaped)</th></tr></thead>
            <tbody>
        \(parentRow)
        \(rows)
            </tbody>
          </table>
        </body>
        </html>
        """
    }

    private func sameHref(_ lhs: String, _ rhs: String) -> Bool {
        normalizedHrefForComparison(lhs) == normalizedHrefForComparison(rhs)
    }

    private func normalizedHrefForComparison(_ href: String) -> String {
        guard href != "/" else { return "/" }
        return href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func parentHref(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmed.split(separator: "/").map(String.init)
        guard components.count > 1 else {
            return "/"
        }

        return "/" + components.dropLast().map(\.urlPathEscaped).joined(separator: "/") + "/"
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "txt", "log", "md":
            return "text/plain; charset=utf-8"
        case "html", "htm":
            return "application/octet-stream"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "pdf":
            return "application/pdf"
        case "json":
            return "application/json"
        default:
            return "application/octet-stream"
        }
    }

    private func addSecurityHeaders(to headers: inout HTTPHeaders) {
        if headers.first(name: "X-Content-Type-Options") == nil {
            headers.add(name: "X-Content-Type-Options", value: "nosniff")
        }
        if headers.first(name: "X-Frame-Options") == nil {
            headers.add(name: "X-Frame-Options", value: "DENY")
        }
        if headers.first(name: "Referrer-Policy") == nil {
            headers.add(name: "Referrer-Policy", value: "no-referrer")
        }
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
}

private struct PropfindEntry {
    let href: String
    let isDirectory: Bool
    let size: Int?
    let modified: Date
}

private struct UploadState {
    let request: HTTPRequestHead
    let route: Route
    let fileHandle: NIOFileHandle
    let existed: Bool
    var bytesReceived: Int
    var nextOffset: Int64
    var writeFuture: EventLoopFuture<Void>
}

private struct WebDAVLock {
    let path: String
    let token: String
    let depth: String
    let owner: String?
    let expiresAt: Date
}

private final class WebDAVLockStore {
    private let lock = NSLock()
    private var locksByToken: [String: WebDAVLock] = [:]

    func create(path: String, depth: String, timeout: TimeInterval, owner: String?) -> WebDAVLock {
        lock.lock()
        defer { lock.unlock() }
        removeExpiredLocked()
        let token = "opaquelocktoken:\(UUID().uuidString)"
        let newLock = WebDAVLock(
            path: normalizedPath(path),
            token: token,
            depth: normalizedDepth(depth),
            owner: owner,
            expiresAt: Date().addingTimeInterval(timeout)
        )
        locksByToken[token] = newLock
        return newLock
    }

    func refresh(path: String, tokens: Set<String>, timeout: TimeInterval) -> WebDAVLock? {
        lock.lock()
        defer { lock.unlock() }
        removeExpiredLocked()
        let normalized = normalizedPath(path)
        for token in tokens {
            guard let existing = locksByToken[token], pathsOverlap(existing.path, normalized) else { continue }
            let refreshed = WebDAVLock(
                path: existing.path,
                token: existing.token,
                depth: existing.depth,
                owner: existing.owner,
                expiresAt: Date().addingTimeInterval(timeout)
            )
            locksByToken[token] = refreshed
            return refreshed
        }
        return nil
    }

    func unlock(path: String, token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        removeExpiredLocked()
        guard let existing = locksByToken[token], pathsOverlap(existing.path, normalizedPath(path)) else {
            return false
        }
        locksByToken.removeValue(forKey: token)
        return true
    }

    func canWrite(path: String, providedTokens: Set<String>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        removeExpiredLocked()
        let normalized = normalizedPath(path)
        return locksByToken.values.allSatisfy { activeLock in
            !lockAffectsWrite(activeLock, writePath: normalized) || providedTokens.contains(activeLock.token)
        }
    }

    func locks(for path: String) -> [WebDAVLock] {
        lock.lock()
        defer { lock.unlock() }
        removeExpiredLocked()
        let normalized = normalizedPath(path)
        return locksByToken.values
            .filter { pathsOverlap($0.path, normalized) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func removeAll() {
        lock.lock()
        locksByToken.removeAll()
        lock.unlock()
    }

    static func normalizedToken(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutBrackets = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        return withoutBrackets.hasPrefix("opaquelocktoken:") ? withoutBrackets : nil
    }

    static func tokens(in header: String) -> [String] {
        let pattern = #"opaquelocktoken:[A-Fa-f0-9\-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        return regex.matches(in: header, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: header) else { return nil }
            return String(header[tokenRange])
        }
    }

    private func removeExpiredLocked() {
        let now = Date()
        locksByToken = locksByToken.filter { $0.value.expiresAt > now }
    }

    private func normalizedDepth(_ depth: String) -> String {
        depth == "0" ? "0" : "infinity"
    }

    private func normalizedPath(_ path: String) -> String {
        guard path != "/" else { return "/" }
        return "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || isAncestor(lhs, of: rhs) || isAncestor(rhs, of: lhs)
    }

    private func lockAffectsWrite(_ lock: WebDAVLock, writePath: String) -> Bool {
        if lock.path == writePath {
            return true
        }
        if lock.depth != "0", isAncestor(lock.path, of: writePath) {
            return true
        }
        return isAncestor(writePath, of: lock.path)
    }

    private func isAncestor(_ ancestor: String, of child: String) -> Bool {
        ancestor == "/" || child.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }
}

private enum WebDAVError: Error {
    case notFound
    case forbidden
    case conflict
    case preconditionFailed
    case locked
    case badRequest
    case tooManyRequests
    case tlsConfiguration(String)
}

extension WebDAVError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .tlsConfiguration(let message):
            return message
        default:
            return nil
        }
    }
}

private final class AuthRateLimiter {
    static let shared = AuthRateLimiter()

    private struct State {
        var failures: Int
        var blockedUntil: Date?
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private let maxFailures = 8
    private let blockDuration: TimeInterval = 60

    func isLimited(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let blockedUntil = states[key]?.blockedUntil else { return false }
        if blockedUntil > Date() {
            return true
        }
        states[key]?.blockedUntil = nil
        states[key]?.failures = 0
        return false
    }

    func recordFailure(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        var state = states[key] ?? State(failures: 0, blockedUntil: nil)
        state.failures += 1
        if state.failures >= maxFailures {
            state.blockedUntil = Date().addingTimeInterval(blockDuration)
        }
        states[key] = state
    }

    func recordSuccess(for key: String) {
        lock.lock()
        states.removeValue(forKey: key)
        lock.unlock()
    }
}

private struct AuthContext {
    let account: Account?
    let permission: PermissionLevel
    let hasEnabledAccounts: Bool
    let requiresAuth: Bool
    let authenticated: Bool

    init(request: HTTPRequestHead, settings: AppSettings, shareID: UUID?) {
        let enabledAccounts = settings.accounts.filter(\.enabled)
        hasEnabledAccounts = !enabledAccounts.isEmpty
        requiresAuth = true

        if let credentials = Self.basicCredentials(from: request.headers.first(name: "Authorization")) {
            account = enabledAccounts.first { account in
                account.hasPassword &&
                PasswordHasher.constantTimeEquals(account.username, credentials.username) &&
                PasswordHasher.constantTimeEquals(account.passwordDigest, PasswordHasher.digest(username: credentials.username, password: credentials.password))
            }
        } else {
            account = nil
        }

        authenticated = account != nil

        if let account {
            if let shareID {
                permission = account.directoryPermissions[shareID] ?? account.defaultPermission
            } else {
                permission = .readOnly
            }
        } else {
            permission = .none
        }
    }

    var isAllowed: Bool {
        authenticated
    }

    var canRead: Bool {
        authenticated && permission.canRead
    }

    var canWrite: Bool {
        authenticated && permission.canWrite
    }

    func permission(for shareID: UUID) -> PermissionLevel {
        guard let account else {
            return .none
        }
        return account.directoryPermissions[shareID] ?? account.defaultPermission
    }

    private static func basicCredentials(from header: String?) -> (username: String, password: String)? {
        guard let header, header.lowercased().hasPrefix("basic ") else { return nil }
        let encoded = String(header.dropFirst(6))
        guard
            let data = Data(base64Encoded: encoded),
            let decoded = String(data: data, encoding: .utf8),
            let separator = decoded.firstIndex(of: ":")
        else {
            return nil
        }

        return (
            username: String(decoded[..<separator]),
            password: String(decoded[decoded.index(after: separator)...])
        )
    }
}

private struct Route {
    let uri: String
    let pathComponents: [String]
    let share: ShareDirectory?
    let fileURL: URL?
    let invalidPath: Bool

    init(uri: String, settings: AppSettings) {
        self.uri = uri
        let path = URLComponents(string: uri)?.percentEncodedPath ?? uri.split(separator: "?").first.map(String.init) ?? uri
        var invalidPath = false
        let components = path
            .split(separator: "/")
            .map { component -> String in
                let decoded = String(component).removingPercentEncoding ?? String(component)
                if decoded == "." ||
                    decoded == ".." ||
                    decoded.contains("/") ||
                    decoded.contains("\0") ||
                    decoded.rangeOfCharacter(from: .controlCharacters) != nil {
                    invalidPath = true
                }
                return decoded
            }

        pathComponents = components
        self.invalidPath = invalidPath

        guard let first = components.first else {
            share = nil
            fileURL = nil
            return
        }

        share = settings.shares.first { $0.enabled && $0.virtualName == first }
        if let share {
            fileURL = components.dropFirst().reduce(URL(fileURLWithPath: share.localPath)) { partial, component in
                partial.appendingPathComponent(component)
            }
        } else {
            fileURL = nil
        }
    }

    var href: String {
        if pathComponents.isEmpty {
            return "/"
        }
        return "/" + pathComponents.map(\.urlPathEscaped).joined(separator: "/")
    }

    var isRoot: Bool {
        pathComponents.isEmpty
    }

    var isHiddenProtected: Bool {
        guard let share, share.protectHiddenFiles else { return false }
        return pathComponents.dropFirst().contains { $0.hasPrefix(".") }
    }

    var logPath: String {
        guard let first = pathComponents.first else { return "/" }
        if pathComponents.count == 1 {
            return "/\(first)"
        }
        return "/\(first)/..."
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    var urlPathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }

    var htmlEscaped: String {
        xmlEscaped.replacingOccurrences(of: "'", with: "&#39;")
    }
}
