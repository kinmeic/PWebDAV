import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

enum WebDAVServerEvent {
    case started(Int)
    case stopped
    case failed(String)
    case request(String)
}

final class WebDAVServerManager {
    private let lock = NSLock()
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var isRunning = false

    func start(settings: AppSettings, settingsProvider: @escaping () -> AppSettings, eventSink: @escaping (WebDAVServerEvent) -> Void) {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: max(2, System.coreCount / 2))

            do {
                let bootstrap = ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.backlog, value: 256)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        channel.pipeline.configureHTTPServerPipeline().flatMap {
                            channel.pipeline.addHandler(WebDAVRequestHandler(settingsProvider: settingsProvider, eventSink: eventSink))
                        }
                    }
                    .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

                let channel = try bootstrap.bind(host: settings.bindAddress, port: settings.port).wait()

                self.lock.lock()
                self.group = group
                self.channel = channel
                self.lock.unlock()

                eventSink(.started(settings.port))
                try channel.closeFuture.wait()
                eventSink(.stopped)
            } catch {
                eventSink(.failed(error.localizedDescription))
            }

            self.lock.lock()
            self.channel = nil
            self.group = nil
            self.isRunning = false
            self.lock.unlock()

            try? group.syncShutdownGracefully()
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.lock.lock()
            let channel = self.channel
            self.lock.unlock()

            if let channel {
                try? channel.close().wait()
            }
            completion?()
        }
    }
}

private final class WebDAVRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let settingsProvider: () -> AppSettings
    private let eventSink: (WebDAVServerEvent) -> Void
    private var currentRequest: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    init(settingsProvider: @escaping () -> AppSettings, eventSink: @escaping (WebDAVServerEvent) -> Void) {
        self.settingsProvider = settingsProvider
        self.eventSink = eventSink
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            currentRequest = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)
        case .body(var body):
            bodyBuffer?.writeBuffer(&body)
        case .end:
            guard let request = currentRequest else { return }
            handle(request: request, body: bodyBuffer, context: context)
            currentRequest = nil
            bodyBuffer = nil
        }
    }

    private func handle(request: HTTPRequestHead, body: ByteBuffer?, context: ChannelHandlerContext) {
        let method = request.method.rawValue
        eventSink(.request("\(method) \(request.uri)"))

        let settings = settingsProvider()
        let route = Route(uri: request.uri, settings: settings)
        let auth = AuthContext(request: request, settings: settings, shareID: route.share?.id)

        guard auth.hasEnabledAccounts else {
            respond(status: .forbidden, context: context, keepAlive: request.isKeepAlive)
            return
        }

        guard auth.isAllowed else {
            respondUnauthorized(context: context, keepAlive: request.isKeepAlive)
            return
        }

        do {
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
                try handlePut(route: route, body: body, context: context, keepAlive: request.isKeepAlive)
            case .DELETE:
                guard auth.canWrite else { throw WebDAVError.forbidden }
                try handleDelete(route: route, context: context, keepAlive: request.isKeepAlive)
            case .MKCOL:
                guard auth.canWrite else { throw WebDAVError.forbidden }
                try handleMkcol(route: route, context: context, keepAlive: request.isKeepAlive)
            case .PROPFIND:
                guard auth.canRead else { throw WebDAVError.forbidden }
                try handlePropfind(route: route, auth: auth, settings: settings, request: request, context: context, keepAlive: request.isKeepAlive)
            case .MOVE:
                guard auth.canWrite else { throw WebDAVError.forbidden }
                try handleMove(route: route, settings: settings, request: request, context: context, keepAlive: request.isKeepAlive)
            case .COPY:
                guard auth.canWrite else { throw WebDAVError.forbidden }
                try handleCopy(route: route, settings: settings, request: request, context: context, keepAlive: request.isKeepAlive)
            default:
                respond(status: .methodNotAllowed, context: context, keepAlive: request.isKeepAlive)
            }
        } catch WebDAVError.notFound {
            respond(status: .notFound, context: context, keepAlive: request.isKeepAlive)
        } catch WebDAVError.forbidden {
            respond(status: .forbidden, context: context, keepAlive: request.isKeepAlive)
        } catch WebDAVError.conflict {
            respond(status: .conflict, context: context, keepAlive: request.isKeepAlive)
        } catch {
            eventSink(.request("ERROR \(method) \(request.uri): \(error.localizedDescription)"))
            respond(status: .internalServerError, context: context, keepAlive: request.isKeepAlive)
        }
    }

    private func respondOptions(context: ChannelHandlerContext, keepAlive: Bool) {
        var headers = HTTPHeaders()
        headers.add(name: "DAV", value: "1,2")
        headers.add(name: "Allow", value: "OPTIONS, PROPFIND, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY")
        headers.add(name: "MS-Author-Via", value: "DAV")
        respond(status: .ok, headers: headers, context: context, keepAlive: keepAlive)
    }

    private func respondGet(route: Route, auth: AuthContext, settings: AppSettings, context: ChannelHandlerContext, keepAlive: Bool, includeBody: Bool) throws {
        if route.isRoot {
            respondHTML(directoryHTML(entries: rootEntries(settings: settings, auth: auth), title: "PWebDAV", path: "/"), context: context, keepAlive: keepAlive, includeBody: includeBody)
            return
        }

        guard let url = route.fileURL else { throw WebDAVError.notFound }
        guard FileManager.default.fileExists(atPath: url.path) else { throw WebDAVError.notFound }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let entries = try fileEntries(route: route, url: url, depth: "1")
            let directoryHref = route.href.hasSuffix("/") ? route.href : route.href + "/"
            respondHTML(directoryHTML(entries: entries, title: directoryHref, path: directoryHref), context: context, keepAlive: keepAlive, includeBody: includeBody)
            return
        }

        let data = try Data(contentsOf: url)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Content-Type", value: mimeType(for: url))

        var responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        if keepAlive {
            responseHead.headers.add(name: "Connection", value: "keep-alive")
        }
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        if includeBody {
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        finish(context: context, keepAlive: keepAlive)
    }

    private func handlePut(route: Route, body: ByteBuffer?, context: ChannelHandlerContext, keepAlive: Bool) throws {
        guard let url = route.fileURL, route.share != nil else { throw WebDAVError.forbidden }
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { throw WebDAVError.conflict }

        var buffer = body ?? context.channel.allocator.buffer(capacity: 0)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let data = Data(bytes)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try data.write(to: url, options: Data.WritingOptions.atomic)
        respond(status: existed ? .noContent : .created, context: context, keepAlive: keepAlive)
    }

    private func handleDelete(route: Route, context: ChannelHandlerContext, keepAlive: Bool) throws {
        guard let url = route.fileURL, route.share != nil else { throw WebDAVError.forbidden }
        guard FileManager.default.fileExists(atPath: url.path) else { throw WebDAVError.notFound }
        try FileManager.default.removeItem(at: url)
        respond(status: .noContent, context: context, keepAlive: keepAlive)
    }

    private func handleMkcol(route: Route, context: ChannelHandlerContext, keepAlive: Bool) throws {
        guard let url = route.fileURL, route.share != nil else { throw WebDAVError.forbidden }
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
        guard let sourceURL = route.fileURL, route.share != nil else { throw WebDAVError.forbidden }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw WebDAVError.notFound }
        guard let destination = request.headers.first(name: "Destination") else { throw WebDAVError.conflict }

        let destinationURI = URL(string: destination)?.path ?? destination
        let destinationRoute = Route(uri: destinationURI, settings: settings)
        let destinationAuth = AuthContext(request: request, settings: settings, shareID: destinationRoute.share?.id)
        guard destinationAuth.canWrite, let targetURL = destinationRoute.fileURL, destinationRoute.share != nil else { throw WebDAVError.forbidden }

        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }

        if shouldMove {
            try FileManager.default.moveItem(at: sourceURL, to: targetURL)
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        }
        respond(status: .created, context: context, keepAlive: keepAlive)
    }

    private func handlePropfind(route: Route, auth: AuthContext, settings: AppSettings, request: HTTPRequestHead?, context: ChannelHandlerContext, keepAlive: Bool) throws {
        let depth = request?.headers.first(name: "Depth") ?? "1"
        let entries: [PropfindEntry]

        if route.isRoot {
            entries = rootEntries(settings: settings, auth: auth)
        } else {
            guard let url = route.fileURL, FileManager.default.fileExists(atPath: url.path) else { throw WebDAVError.notFound }
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

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else { return [base] }

        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .map { child -> PropfindEntry in
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
        let promise = keepAlive ? nil : context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        promise?.futureResult.whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private func modifiedDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? Date()
    }

    private func propfindXML(entries: [PropfindEntry]) -> String {
        let responses = entries.map { entry in
            let resourceType = entry.isDirectory ? "<D:collection/>" : ""
            let contentLength = entry.size.map { "<D:getcontentlength>\($0)</D:getcontentlength>" } ?? ""
            return """
            <D:response>
              <D:href>\(entry.href.xmlEscaped)</D:href>
              <D:propstat>
                <D:prop>
                  <D:resourcetype>\(resourceType)</D:resourcetype>
                  \(contentLength)
                  <D:getlastmodified>\(Self.httpDateFormatter.string(from: entry.modified))</D:getlastmodified>
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
            return "text/html; charset=utf-8"
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

private enum WebDAVError: Error {
    case notFound
    case forbidden
    case conflict
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
                account.username == credentials.username &&
                account.passwordDigest == PasswordHasher.digest(username: credentials.username, password: credentials.password)
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

    init(uri: String, settings: AppSettings) {
        self.uri = uri
        let path = URLComponents(string: uri)?.percentEncodedPath ?? uri.split(separator: "?").first.map(String.init) ?? uri
        let components = path
            .split(separator: "/")
            .compactMap { component -> String? in
                let decoded = String(component).removingPercentEncoding ?? String(component)
                guard decoded != ".", decoded != "..", !decoded.contains("/") else { return nil }
                return decoded
            }

        pathComponents = components

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
