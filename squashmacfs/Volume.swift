//
//  Volume.swift
//  squashmac
//
//  Created by Anthony Li on 2/18/26.
//

import FSKit

let sqfs_name_empty: sqfs_name = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

extension sqfs_dir_entry {
    mutating func filename() -> FSFileName {
        let namePtr = sqfs_dentry_name(&self)!
        let nameData = Data(bytes: UnsafeRawPointer(namePtr), count: sqfs_dentry_name_size(&self))
        return FSFileName(data: nameData)
    }
}

class Volume: FSVolume, FSVolume.Operations, FSVolume.PathConfOperations, FSVolume.ReadWriteOperations {
    var path: String
    var fs: UnsafeMutablePointer<sqfs>
    var fsDestroyed = false
    var root: Item?
    
    init(path: String, name: String) {
        self.path = path
        self.fs = UnsafeMutablePointer.allocate(capacity: 1)
        super.init(volumeID: .init(uuid: UUID()), volumeName: FSFileName(string: name))
    }
    
    deinit {
        fs.deallocate()
    }
    
    // MARK: - Lifecycle
    
    func activate(options: FSTaskOptions) async throws -> FSItem {
        let root = Item(parent: .parentOfRoot)
        self.root = root
        
        memset(fs, 0, MemoryLayout<sqfs>.size)
        guard sqfs_open_image(fs, path, 0) == SQFS_OK else {
            throw POSIXError(.EIO)
        }
        
        fsDestroyed = false
        root.allocate()
        guard sqfs_inode_get(fs, root.inode!, sqfs_inode_root(fs)) == SQFS_OK else {
            destroy()
            throw POSIXError(.EIO)
        }
        
        return root
    }
    
    func mount(options: FSTaskOptions) async throws {
        
    }
    
    private func destroy() {
        guard !fsDestroyed else {
            return
        }
        
        root?.deallocate()
        sqfs_destroy(fs)
        fsDestroyed = true
    }
    
    func unmount() async {
        
    }
    
    func deactivate(options: FSDeactivateOptions = []) async throws {
        destroy()
        root = nil
    }
    
    // MARK: - Items
    
    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        guard let diritem = directory as? Item, let dirnode = diritem.inode else {
            throw POSIXError(.EINVAL)
        }
        
        var found = false
        var entry = sqfs_dir_entry()
        var namebuf = sqfs_name_empty
        sqfs_dentry_init(&entry, &namebuf)
        
        try name.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            try bytes.withMemoryRebound(to: CChar.self) { name in
                guard let base = name.baseAddress else {
                    throw POSIXError(.EIO)
                }
                
                guard sqfs_dir_lookup(fs, dirnode, base, name.count, &entry, &found) == SQFS_OK else {
                    throw POSIXError(.EINVAL)
                }
            }
        }
        
        if !found {
            throw POSIXError(.ENOENT)
        }
        
        let item = Item(parent: diritem.identifier)
        item.allocate()
        guard sqfs_inode_get(fs, item.inode, sqfs_dentry_inode(&entry)) == SQFS_OK else {
            throw POSIXError(.ENOENT)
        }
        
        return (item, entry.filename())
    }
    
    func reclaimItem(_ item: FSItem) async throws {
        if let item = item as? Item {
            item.deallocate()
        }
    }
    
    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let item = item as? Item, let inode = item.inode else {
            throw POSIXError(.EINVAL)
        }
        
        guard (inode.pointee.base.mode & S_IFMT) == S_IFLNK else {
            throw POSIXError(.EINVAL)
        }
        
        var size = 0
        guard sqfs_readlink(fs, inode, nil, &size) == SQFS_OK else {
            throw POSIXError(.EIO)
        }
        
        var data = Data(count: size + 1)
        try data.withUnsafeMutableBytes { bytes in
            try bytes.withMemoryRebound(to: CChar.self) { buf in
                guard sqfs_readlink(fs, inode, buf.baseAddress!, &size) == SQFS_OK else {
                    throw POSIXError(.EIO)
                }
            }
        }
        
        guard data.last == 0 else {
            throw POSIXError(.EIO)
        }
        
        data.removeLast()
        
        return FSFileName(data: data)
    }
    
    func getAttributes(_ desired: FSItem.GetAttributesRequest, of item: FSItem) throws -> FSItem.Attributes {
        guard let item = item as? Item, let inode = item.inode else {
            throw POSIXError(.EINVAL)
        }
        
        let type: FSItem.ItemType
        switch inode.pointee.base.mode & S_IFMT {
        case S_IFDIR:
            type = .directory
        case S_IFLNK:
            type = .symlink
        case S_IFBLK:
            type = .blockDevice
        case S_IFCHR:
            type = .charDevice
        case S_IFIFO:
            type = .file
        case S_IFREG:
            type = .file
        case S_IFSOCK:
            type = .socket
        default:
            type = .unknown
        }
        
        let attrs = FSItem.Attributes()
        if desired.isAttributeWanted(.type) {
            attrs.type = type
        }
        
        if desired.isAttributeWanted(.mode) {
            attrs.mode = UInt32(inode.pointee.base.mode)
        }
        
        if desired.isAttributeWanted(.linkCount) {
            attrs.linkCount = UInt32(inode.pointee.nlink)
        }
        
        if desired.isAttributeWanted(.allocSize) {
            if type == .file {
                let size = inode.pointee.xtra.reg.file_size
                attrs.allocSize = (size / 512) * 512
            } else {
                attrs.allocSize = 0
            }
        }
        
        if desired.isAttributeWanted(.size) {
            if type == .file {
                attrs.size = inode.pointee.xtra.reg.file_size
            } else {
                attrs.allocSize = 0
            }
        }
        
        if desired.isAttributeWanted(.fileID) {
            attrs.fileID = item.identifier
        }
        
        if desired.isAttributeWanted(.parentID) {
            attrs.parentID = item.parent
        }
        
        if desired.isAttributeWanted(.flags) {
            attrs.flags = 0
        }
        
        let time = timespec(tv_sec: time_t(inode.pointee.base.mtime), tv_nsec: 0)
        
        if desired.isAttributeWanted(.accessTime) {
            attrs.accessTime = time
        }
        
        if desired.isAttributeWanted(.modifyTime) {
            attrs.modifyTime = time
        }
        
        if desired.isAttributeWanted(.changeTime) {
            attrs.changeTime = time
        }
        
        if desired.isAttributeWanted(.birthTime) {
            attrs.birthTime = time
        }
        
        if desired.isAttributeWanted(.uid) {
            if fs.pointee.uid > 0 {
                attrs.uid = UInt32(fs.pointee.uid)
            } else {
                var id: sqfs_id_t = 0
                guard sqfs_id_get(fs, inode.pointee.base.uid, &id) == SQFS_OK else {
                    throw POSIXError(.EIO)
                }
                attrs.uid = id
            }
        }
        
        if desired.isAttributeWanted(.gid) {
            if fs.pointee.gid > 0 {
                attrs.gid = UInt32(fs.pointee.gid)
            } else {
                var id: sqfs_id_t = 0
                guard sqfs_id_get(fs, inode.pointee.base.guid, &id) == SQFS_OK else {
                    throw POSIXError(.EIO)
                }
                attrs.gid = id
            }
        }
        
        return attrs
    }
    
    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        try getAttributes(desiredAttributes, of: item)
    }
        
    func enumerate(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker) throws -> FSDirectoryVerifier {
        guard let diritem = directory as? Item, let dirnode = diritem.inode else {
            throw POSIXError(.EINVAL)
        }
        
        guard (dirnode.pointee.base.mode & S_IFMT) == S_IFDIR else {
            throw POSIXError(.ENOTDIR)
        }
        
        var dir = sqfs_dir()
        let offset: off_t = cookie == FSDirectoryCookie.initial ? 0 : off_t(cookie.rawValue)
        
        guard sqfs_dir_open(fs, dirnode, &dir, offset) == SQFS_OK else {
            throw POSIXError(.EIO)
        }
        
        var entry = sqfs_dir_entry()
        var namebuf = sqfs_name_empty
        sqfs_dentry_init(&entry, &namebuf)
        
        var sqerr = SQFS_OK
        while sqfs_dir_next(fs, &dir, &entry, &sqerr) {
            let nextOffset = sqfs_dentry_next_offset(&entry)
            let itemType: FSItem.ItemType
            switch sqfs_dentry_type(&entry) {
            case SQUASHFS_DIR_TYPE, SQUASHFS_LDIR_TYPE:
                itemType = .directory
            case SQUASHFS_REG_TYPE, SQUASHFS_LREG_TYPE:
                itemType = .file
            case SQUASHFS_SYMLINK_TYPE, SQUASHFS_LSYMLINK_TYPE:
                itemType = .symlink
            case SQUASHFS_BLKDEV_TYPE, SQUASHFS_LBLKDEV_TYPE:
                itemType = .blockDevice
            case SQUASHFS_CHRDEV_TYPE, SQUASHFS_LCHRDEV_TYPE:
                itemType = .charDevice
            case SQUASHFS_FIFO_TYPE, SQUASHFS_LFIFO_TYPE:
                itemType = .fifo
            case SQUASHFS_SOCKET_TYPE, SQUASHFS_LSOCKET_TYPE:
                itemType = .socket
            default:
                itemType = .unknown
            }
            
            var itemAttributes: FSItem.Attributes?
            if let request = attributes {
                let item = Item(parent: diritem.identifier)
                item.allocate()
                guard sqfs_inode_get(fs, item.inode, sqfs_dentry_inode(&entry)) == SQFS_OK else {
                    throw POSIXError(.EIO)
                }
                
                itemAttributes = try self.getAttributes(request, of: item)
            }
            
            if !packer.packEntry(name: entry.filename(), itemType: itemType, itemID: FSItem.Identifier(rawValue: UInt64(entry.inode_number)) ?? .invalid, nextCookie: FSDirectoryCookie(UInt64(nextOffset)), attributes: itemAttributes) {
                break
            }
        }
        
        guard sqerr == SQFS_OK else {
            throw POSIXError(.EIO)
        }
        
        return FSDirectoryVerifier.initial
    }
    
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        do {
            reply(try enumerate(directory, startingAt: cookie, verifier: verifier, attributes: attributes, packer: packer), nil)
        } catch {
            reply(FSDirectoryVerifier.initial, error)
        }
    }
    
    // MARK: - Reading
    
    func doRead(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
        guard let item = item as? Item, let inode = item.inode else {
            throw POSIXError(.EINVAL)
        }
        
        let type = inode.pointee.base.mode & S_IFMT
        guard type == S_IFREG else {
            if type == S_IFDIR {
                throw POSIXError(.EISDIR)
            } else {
                throw POSIXError(.EINVAL)
            }
        }
        
        guard length <= buffer.length, offset >= 0 else {
            throw POSIXError(.EINVAL)
        }
        
        if offset > inode.pointee.xtra.reg.file_size {
            return 0
        }
        
        var size = off_t(length)
        try buffer.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else {
                throw POSIXError(.EIO)
            }
            
            guard sqfs_read_range(fs, inode, offset, &size, base) == SQFS_OK else {
                throw POSIXError(.EIO)
            }
        }
        
        return Int(size)
    }
    
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        do {
            reply(try doRead(from: item, at: offset, length: length, into: buffer), nil)
        } catch {
            reply(0, error)
        }
    }
    
    // MARK: - Volume Operations
    
    func synchronize(flags: FSSyncFlags) async throws {
        return
    }
    
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsSymbolicLinks = true
        capabilities.caseFormat = .sensitive
        capabilities.supportsHiddenFiles = false
        capabilities.supports2TBFiles = true
        capabilities.supportsFastStatFS = true
        return capabilities
    }
    
    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "squashfs")
        
        result.blockSize = Int(fs.pointee.sb.block_size)
        result.totalBytes = fs.pointee.sb.bytes_used
        result.freeBytes = 0
        result.availableBytes = 0
        result.totalFiles = UInt64(fs.pointee.sb.inodes)
        result.freeFiles = 0
        
        return result
    }
    
    // MARK: - Path Conf Operations
    
    var maximumLinkCount: Int {
        Int(_POSIX_LINK_MAX)
    }
    
    var maximumNameLength: Int {
        Int(SQUASHFS_NAME_LEN)
    }
    
    var restrictsOwnershipChanges: Bool {
        true
    }
    
    var truncatesLongNames: Bool {
        false
    }
    
    var maximumFileSizeInBits: Int {
        64
    }
    
    var maximumXattrSizeInBits: Int {
        64
    }
    
    // MARK: - Read-Only Stubs
    
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        throw POSIXError(.EROFS)
    }
    
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        throw POSIXError(.EROFS)
    }
    
    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, POSIXError(.EROFS))
    }
    
    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        throw POSIXError(.EROFS)
    }
    
    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        throw POSIXError(.EROFS)
    }
    
    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        throw POSIXError(.EROFS)
    }
    
    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        reply(0, POSIXError(.EROFS))
    }
}
