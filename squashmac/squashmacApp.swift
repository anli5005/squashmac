//
//  squashmacApp.swift
//  squashmac
//
//  Created by Anthony Li on 2/18/26.
//

import SwiftUI
import OSLog

func getSupportDirectory(create: Bool) throws -> URL {
    let applicationSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let squashmacSupport = applicationSupport.appendingPathComponent("squashmac")
    if create, !FileManager.default.fileExists(atPath: squashmacSupport.path) {
        try FileManager.default.createDirectory(at: squashmacSupport, withIntermediateDirectories: false, attributes: nil)
    }
    
    return squashmacSupport
}

func getMountDirectory(create: Bool) throws -> URL {
    let support = try getSupportDirectory(create: create)
    let mount = support.appendingPathComponent("Volumes")
    if create, !FileManager.default.fileExists(atPath: mount.path) {
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false, attributes: nil)
    }
    
    return mount
}

func cleanupManagedMountPoints() throws {
    let dir = try getMountDirectory(create: false)
    let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isVolumeKey])
    for file in contents {
        let isVolume = try file.resourceValues(forKeys: [.isVolumeKey]).isVolume
        if isVolume == false {
            Logger.squashmac.info("Removing \(file)")
            try FileManager.default.removeItem(at: file)
        }
    }
}

func findMountPoint(for url: URL) throws -> URL {
    var suggestedName = url.deletingPathExtension().lastPathComponent
    if suggestedName.isEmpty {
        suggestedName = "SquashFS Filesystem"
    }
    
    let dir = try getMountDirectory(create: true)
    var candidate = dir.appendingPathComponent(suggestedName)
    var tries = 1
    while FileManager.default.fileExists(atPath: candidate.path) {
        tries += 1
        if tries == 100 {
            throw POSIXError(.EBUSY)
        }
        
        candidate = dir.appendingPathComponent("\(suggestedName) (\(tries))")
    }
    
    return candidate
}

func mount(archiveAt archiveURL: URL) async throws -> URL {
    let point = try findMountPoint(for: archiveURL)
    Logger.squashmac.info("Selected mount point \(point)")
    
    try FileManager.default.createDirectory(at: point, withIntermediateDirectories: false)
    
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        do {
            try Process.run(URL(filePath: "/sbin/mount"), arguments: ["-t", "squashfs", archiveURL.path(percentEncoded: false), point.path(percentEncoded: false)]) { process in
                Logger.squashmac.info("mount(8) returned \(process.terminationStatus)")
                
                guard process.terminationStatus == 0 else {
                    continuation.resume(with: .failure(POSIXError(.EIO)))
                    return
                }
                
                continuation.resume(with: .success(()))
            }
        } catch {
            continuation.resume(with: .failure(error))
        }
    }
    
    return point
}

extension Logger {
    static let squashmac = Logger(subsystem: "dev.anli.macos.squashmac", category: "squashmac")
}

@main
struct squashmacApp: App {
    init() {
        do {
            try cleanupManagedMountPoints()
        } catch {
            Logger.squashmac.warning("Couldn't clean up mount points: \(error)")
        }
    }
    
    var body: some Scene {
        Window("squashmac", id: "main") {
            ContentView()
                .onOpenURL { url in
                    guard url.isFileURL else {
                        Logger.squashmac.warning("Requested to open non-file URL \(url)")
                        return
                    }
                    
                    Logger.squashmac.info("Attempting mount of \(url)")
                    
                    do {
                        try cleanupManagedMountPoints()
                    } catch {
                        Logger.squashmac.warning("Couldn't clean up mount points: \(error)")
                    }
                    
                    Task {
                        do {
                            let mountPoint = try await mount(archiveAt: url)
                            NSWorkspace.shared.open(mountPoint)
                        } catch {
                            Logger.squashmac.error("Failed to mount \(url): \(error)")
                        }
                    }
                }
        }
    }
}
