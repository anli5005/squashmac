//
//  Item.swift
//  squashmac
//
//  Created by Anthony Li on 2/18/26.
//

import FSKit

class Item: FSItem {
    var inode: UnsafeMutablePointer<sqfs_inode>?
    var parent: FSItem.Identifier
    
    init(parent: FSItem.Identifier) {
        self.parent = parent
    }
    
    func allocate() {
        precondition(inode == nil)
        inode = .allocate(capacity: 1)
    }
    
    func deallocate() {
        inode?.deallocate()
        inode = nil
    }
    
    deinit {
        inode?.deallocate()
    }
    
    var identifier: FSItem.Identifier {
        if parent == .parentOfRoot {
            .rootDirectory
        } else if let inode {
            .init(rawValue: UInt64(inode.pointee.base.inode_number)) ?? .invalid
        } else {
            .invalid
        }
    }
}
