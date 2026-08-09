// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import os.log

extension FileManager {
    static var appGroupId: String? {
        #if os(iOS)
        let appGroupIdInfoDictionaryKey = "com.wireguard.ios.app_group_id"
        #elseif os(macOS)
        let appGroupIdInfoDictionaryKey = "com.wireguard.macos.app_group_id"
        #else
        #error("Unimplemented")
        #endif
        return Bundle.main.object(forInfoDictionaryKey: appGroupIdInfoDictionaryKey) as? String
    }
    private static var sharedFolderURL: URL? {
        guard let appGroupId = FileManager.appGroupId else {
            os_log("Cannot obtain app group ID from bundle", log: OSLog.default, type: .error)
            return nil
        }
        guard let sharedFolderURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            wg_log(.error, message: "Cannot obtain shared folder URL")
            return nil
        }
        return sharedFolderURL
    }

    static var logFileURL: URL? {
        return sharedFolderURL?.appendingPathComponent("tunnel-log.bin")
    }

    static var networkExtensionLastErrorFileURL: URL? {
        return sharedFolderURL?.appendingPathComponent("last-error.txt")
    }

    static var loginHelperTimestampURL: URL? {
        return sharedFolderURL?.appendingPathComponent("login-helper-timestamp.bin")
    }

    static var wsTlsDirectoryURL: URL? {
        return sharedFolderURL?.appendingPathComponent("ws-tls", isDirectory: true)
    }

    enum WsTlsImportError: Error {
        case noAppGroupContainer
        case copyFailed(Error)
    }

    static func importWsTlsFile(from url: URL) throws -> URL {
        guard let directory = wsTlsDirectoryURL else { throw WsTlsImportError.noAppGroupContainer }
        let sanitized = url.lastPathComponent.map { character -> Character in
            return character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" ? character : "_"
        }
        // An empty or all-dots name ("." / "..") would escape the ws-tls directory
        // (allSatisfy is true for the empty case too).
        let isUnusableName = sanitized.allSatisfy { $0 == "." }
        let fileName = isUnusableName ? "ws-tls" : String(sanitized)
        let destination = directory.appendingPathComponent(fileName)
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw WsTlsImportError.copyFailed(error)
        }
        return destination
    }

    static func deleteFile(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            return false
        }
        return true
    }
}
