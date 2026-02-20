//
//  squashmacfsFileSystem.swift
//  squashmacfs
//
//  Created by Anthony Li on 2/18/26.
//

import Foundation
import FSKit

@objc
class squashmacfsFileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
    func getName(from pathResource: FSPathURLResource) -> String {
        let name = pathResource.url.lastPathComponent
        if name.isEmpty {
            return "SquashFS Filesystem"
        }
        
        return name
    }
    
    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let pathResource = resource as? FSPathURLResource, pathResource.url.isFileURL, pathResource.url.startAccessingSecurityScopedResource() else {
            return .notRecognized
        }
        
        defer {
            pathResource.url.stopAccessingSecurityScopedResource()
        }
        
        let handle = try FileHandle(forReadingFrom: pathResource.url)
        let recognized: Bool
        
        do {
            let data = try handle.read(upToCount: 4)
            if let data {
                recognized = data.elementsEqual([0x73, 0x71, 0x73, 0x68] as [UInt8])
            } else {
                recognized = false
            }
        } catch {
            try handle.close()
            throw error
        }
        
        try handle.close()
        
        if recognized {
            return .recognized(name: "", containerID: FSContainerIdentifier(uuid: UUID()))
        } else {
            return .notRecognized
        }
    }
    
    func loadResource(resource: FSResource, options: FSTaskOptions) async throws -> FSVolume {
        containerStatus = .ready
        
        guard let pathResource = resource as? FSPathURLResource else {
            throw POSIXError(.ENOTSUP)
        }
        
        guard pathResource.url.isFileURL else {
            throw POSIXError(.EINVAL)
        }
        
        _ = pathResource.url.startAccessingSecurityScopedResource()
        let path = pathResource.url.path(percentEncoded: false)
                
        return Volume(path: path, name: getName(from: pathResource))
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
        if let pathResource = resource as? FSPathURLResource {
            pathResource.url.stopAccessingSecurityScopedResource()
        }
    }
}
