//
//  squashmacfs.swift
//  squashmacfs
//
//  Created by Anthony Li on 2/18/26.
//

import ExtensionFoundation
import Foundation
import FSKit

@main
struct squashmacfs : UnaryFileSystemExtension {
    var fileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
        squashmacfsFileSystem()
    }
}
