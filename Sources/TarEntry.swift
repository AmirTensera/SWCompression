// Copyright (c) 2017 Timofey Solomko
// Licensed under MIT License
//
// See LICENSE for license information

import Foundation

/// Represents either a file or directory entry in TAR container.
public class TarEntry: ContainerEntry {

    /**
     Represents a type of an entry.

     - Warning:
     Deprecated and will be removed in 4.0. `FileAttributeType` values will be used instead.
     */
    public enum EntryType: String {
        /// Normal file.
        case normal = "0"
        /// Hard linked entry.
        case hardLink = "1"
        /// Symbolically linked entry.
        case symbolicLink = "2"
        /// Character special file.
        case characterSpecial = "3"
        /// Block special file.
        case blockSpecial = "4"
        /// Directory.
        case directory = "5"
        /// FIFO special file.
        case fifo = "6"
        /// Contiguous file.
        case contiguous = "7"
        /// PAX global extended header. (Should not be encountered separately).
        case globalExtendedHeader = "g"
        /// PAX local extended header. (Should not be encountered separately).
        case localExtendedHeader = "x"
        /// Either unknown type, vendor specific or reserved value.
        case vendorUnknownOrReserved
    }

    /// Name of the file or directory.
    public var name: String {
        return paxPath ?? ((fileNamePrefix ?? "") + (fileName ?? ""))
    }

    /// True, if an entry is a directory.
    public var isDirectory: Bool {
        return (type == .directory) || (type == .normal && size == 0 && name.characters.last == "/")
    }

    /// Size of the data associated with the entry.
    public private(set) var size: Int

    /**
     Provides a dictionary with various attributes of the entry.
     `FileAttributeKey` values are used as dictionary keys.

     - Note:
     Will be renamed in 4.0.

     ## Possible attributes:

     - `FileAttributeKey.posixPermissions`,
     - `FileAttributeKey.ownerAccountID`,
     - `FileAttributeKey.groupOwnerAccountID`,
     - `FileAttributeKey.size`,
     - `FileAttributeKey.modificationDate`,
     - `FileAttributeKey.type`,
     - `FileAttributeKey.ownerAccountName`, if format of container is UStar,
     - `FileAttributeKey.groupOwnerAccountName`, if format of container is UStar.

     Most modern TAR containers are in UStar format.
     */
    public let entryAttributes: [FileAttributeKey: Any]

    /**
     File mode.

     - Warning:
     Deprecated and will be removed in 4.0. Use `entryAttributes` instead.
     */
    public let mode: Int?

    /**
     Owner's ID.

     - Warning:
     Deprecated and will be removed in 4.0. Use `entryAttributes` instead.
     */
    public private(set) var ownerID: Int?

    /**
     Owner's group ID.

     - Warning:
     Deprecated and will be removed in 4.0. Use `entryAttributes` instead.
     */
    public private(set) var groupID: Int?

    /**
     The most recent modification time of the original file or directory.

     - Warning:
     Deprecated and will be removed in 4.0. Use `entryAttributes` instead.
     */
    public private(set) var modificationTime: Date

    /**
     Type of entry.

     - Warning:
     Deprecated and will be removed in 4.0. Use `entryAttributes` instead.
     */
    public let type: EntryType

    /**
     Owner's user name.

     - Warning:
     Deprecated and will be removed in 4.0. Use `entryAttributes` instead.
     */
    public private(set) var ownerUserName: String?

    /**
     Owner's group name.

     - Warning:
     Deprecated and will be removed in 4.0. Use `entryAttributes` instead.
     */
    public private(set) var ownerGroupName: String?

    private let deviceMajorNumber: String?
    private let deviceMinorNumber: String?

    private let fileName: String?
    private let fileNamePrefix: String?
    private let linkedFileName: String?
    private var paxPath: String?

    private let dataObject: Data

    /// The most recent access time of the original file or directory (PAX only).
    public private(set) var accessTime: Date?

    /// Name of the character set used to encode entry's data (PAX only).
    public private(set) var charset: String?

    /// Comment associated with the entry (PAX only).
    public private(set) var comment: String?

    /// Path to a linked file.
    public var linkPath: String? {
        return paxLinkPath ?? linkedFileName
    }

    private var paxLinkPath: String?

    /// Other entries from PAX extended headers.
    public private(set) var unknownExtendedHeaderEntries: [String: String] = [:]

    init(_ data: Data, _ index: inout Int,
                     _ globalExtendedHeader: String?, _ localExtendedHeader: String?) throws {
        var attributesDict = [FileAttributeKey: Any]()

        let blockStartIndex = index
        // File name
        fileName = try data.nullEndedAsciiString(index, 100)
        index += 100

        // File mode
        guard let octalPosixPermissions = Int(try data.nullSpaceEndedAsciiString(index, 8))
            else { throw TarError.fieldIsNotNumber }
        let posixPermissions = octalPosixPermissions.octalToDecimal()
        attributesDict[FileAttributeKey.posixPermissions] = posixPermissions
        mode = posixPermissions
        index += 8

        // Owner's user ID
        guard let ownerAccountID = Int(try data.nullSpaceEndedAsciiString(index, 8))
            else { throw TarError.fieldIsNotNumber }
        attributesDict[FileAttributeKey.ownerAccountID] = ownerAccountID
        ownerID = ownerAccountID
        index += 8

        // Group's user ID
        guard let groupAccountID = Int(try data.nullSpaceEndedAsciiString(index, 8))
            else { throw TarError.fieldIsNotNumber }
        attributesDict[FileAttributeKey.groupOwnerAccountID] = groupAccountID
        groupID = groupAccountID
        index += 8

        // File size
        guard let octalFileSize = Int(try data.nullSpaceEndedAsciiString(index, 12))
            else { throw TarError.fieldIsNotNumber }
        let fileSize = octalFileSize.octalToDecimal()
        attributesDict[FileAttributeKey.size] = fileSize
        size = fileSize
        index += 12

        // Modification time
        guard let octalMtime = Int(try data.nullSpaceEndedAsciiString(index, 12))
            else { throw TarError.fieldIsNotNumber }
        let mtime = Date(timeIntervalSince1970: TimeInterval(octalMtime.octalToDecimal()))
        attributesDict[FileAttributeKey.modificationDate] = mtime
        modificationTime = mtime
        index += 12

        // Checksum
        guard let octalChecksum = Int(try data.nullSpaceEndedAsciiString(index, 8))
            else { throw TarError.fieldIsNotNumber }
        let checksum = octalChecksum.octalToDecimal()

        var headerDataForChecksum = data.subdata(in: blockStartIndex..<blockStartIndex + 512).toArray(type: UInt8.self)
        for i in 148..<156 {
            headerDataForChecksum[i] = 0x20
        }

        // Some implementations treat bytes as signed integers, but some don't.
        // So we check both cases, coincedence in one of them will pass the checksum test.
        let unsignedOurChecksumArray = headerDataForChecksum.map { UInt($0) }
        let signedOurChecksumArray = headerDataForChecksum.map { Int($0) }

        let unsignedOurChecksum = unsignedOurChecksumArray.reduce(0) { $0 + $1 }
        let signedOurChecksum = signedOurChecksumArray.reduce(0) { $0 + $1 }
        guard unsignedOurChecksum == UInt(checksum) || signedOurChecksum == checksum
            else { throw TarError.wrongHeaderChecksum }

        index += 8

        // File type
        let fileType = EntryType(rawValue: String(Character(UnicodeScalar(data[index])))) ?? .vendorUnknownOrReserved
        type = fileType
        switch fileType {
        case .normal:
            attributesDict[FileAttributeKey.type] = FileAttributeType.typeRegular
        case .symbolicLink:
            attributesDict[FileAttributeKey.type] = FileAttributeType.typeSymbolicLink
        case .characterSpecial:
            attributesDict[FileAttributeKey.type] = FileAttributeType.typeCharacterSpecial
        case .blockSpecial:
            attributesDict[FileAttributeKey.type] = FileAttributeType.typeBlockSpecial
        case .directory:
            attributesDict[FileAttributeKey.type] = FileAttributeType.typeDirectory
        default:
            attributesDict[FileAttributeKey.type] = FileAttributeType.typeUnknown
        }

        index += 1

        // Linked file name
        linkedFileName = try data.nullEndedAsciiString(index, 100)
        index += 100

        let posixIndicator = String(data: data.subdata(in: 257..<263), encoding: .ascii)
        if posixIndicator == "ustar\u{00}" || posixIndicator == "ustar\u{20}" {
            index += 6

            let ustarVersion = String(data: data.subdata(in: index..<index + 2), encoding: .ascii)
            guard ustarVersion == "00" else { throw TarError.wrongUstarVersion }
            index += 2

            let ownerName = try data.nullEndedAsciiString(index, 32)
            attributesDict[FileAttributeKey.ownerAccountName] = ownerName
            ownerUserName = ownerName
            index += 32

            let groupName = try data.nullEndedAsciiString(index, 32)
            attributesDict[FileAttributeKey.groupOwnerAccountName] = groupName
            ownerGroupName = groupName
            index += 32

            deviceMajorNumber = try data.nullSpaceEndedAsciiString(index, 8)
            index += 8

            deviceMinorNumber = try data.nullSpaceEndedAsciiString(index, 8)
            index += 8

            fileNamePrefix = try data.nullEndedAsciiString(index, 155)
            index += 155
        } else {
            ownerUserName = nil
            ownerGroupName = nil
            deviceMajorNumber = nil
            deviceMinorNumber = nil
            fileNamePrefix = nil
        }

        func parseHeader(_ header: String?, _ fieldsDict: inout [String : String]) throws {
            if let headerString = header {
                let headerEntries = headerString.components(separatedBy: "\n")
                for headerEntry in headerEntries {
                    if headerEntry == "" {
                        continue
                    }
                    let headerEntrySplit = headerEntry.characters.split(separator: " ", maxSplits: 1,
                                                                        omittingEmptySubsequences: false)
                    guard Int(String(headerEntrySplit[0])) == headerEntry.characters.count + 1
                        else { throw TarError.wrongPaxHeaderEntry }
                    let keywordValue = String(headerEntrySplit[1])
                    let keywordValueSplit = keywordValue.characters.split(separator: "=", maxSplits: 1,
                                                                          omittingEmptySubsequences: false)
                    let keyword = String(keywordValueSplit[0])
                    let value = String(keywordValueSplit[1])
                    fieldsDict[keyword] = value
                }
            }
        }

        var fieldsDict = [String: String]()
        try parseHeader(globalExtendedHeader, &fieldsDict)
        try parseHeader(localExtendedHeader, &fieldsDict)

        for (keyword, value) in fieldsDict {
            switch keyword {
            case "atime":
                if let interval = Double(value) {
                    self.accessTime = Date(timeIntervalSince1970: interval)
                }
            case "charset":
                self.charset = value
            case "mtime":
                if let interval = Double(value) {
                    let newMtime = Date(timeIntervalSince1970: interval)
                    attributesDict[FileAttributeKey.modificationDate] = newMtime
                    self.modificationTime = newMtime
                }
            case "comment":
                self.comment = value
            case "gid":
                if let newValue = Int(value) {
                    attributesDict[FileAttributeKey.groupOwnerAccountID] = newValue
                }
                self.groupID = Int(value)
            case "gname":
                attributesDict[FileAttributeKey.groupOwnerAccountName] = value
                self.ownerGroupName = value
            case "hdrcharset":
                break
            case "linkpath":
                self.paxLinkPath = value
            case "path":
                self.paxPath = value
            case "size":
                if let intValue = Int(value) {
                    self.size = intValue
                }
            case "uid":
                if let newValue = Int(value) {
                    attributesDict[FileAttributeKey.ownerAccountID] = newValue
                }
                self.ownerID = Int(value)
            case "uname":
                attributesDict[FileAttributeKey.ownerAccountName] = value
                self.ownerUserName = value
            default:
                self.unknownExtendedHeaderEntries[keyword] = value
            }
        }

        self.entryAttributes = attributesDict
        
        // File data
        index = blockStartIndex + 512
        self.dataObject = data.subdata(in: index..<index + size)
        index += size
        index = index.roundTo512()
    }
    
    /// Returns data associated with this entry.
    public func data() -> Data {
        return dataObject
    }
    
}

fileprivate extension Data {

    fileprivate func nullEndedBuffer(_ startIndex: Int, _ cutoff: Int) -> [UInt8] {
        var index = startIndex
        var buffer = [UInt8]()
        while true {
            if self[index] == 0 || index - startIndex >= cutoff {
                break
            }
            buffer.append(self[index])
            index += 1
        }
        return buffer
    }

    fileprivate func nullEndedAsciiString(_ startIndex: Int, _ cutoff: Int) throws -> String {
        if let string = String(bytes: self.nullEndedBuffer(startIndex, cutoff), encoding: .ascii) {
            return string
        } else {
            throw TarError.notAsciiString
        }
    }

    fileprivate func nullSpaceEndedBuffer(_ startIndex: Int, _ cutoff: Int) -> [UInt8] {
        var index = startIndex
        var buffer = [UInt8]()
        while true {
            if self[index] == 0 || self[index] == 0x20 || index - startIndex >= cutoff {
                break
            }
            buffer.append(self[index])
            index += 1
        }
        return buffer
    }

    fileprivate func nullSpaceEndedAsciiString(_ startIndex: Int, _ cutoff: Int) throws -> String {
        if let string = String(bytes: self.nullSpaceEndedBuffer(startIndex, cutoff), encoding: .ascii) {
            return string
        } else {
            throw TarError.notAsciiString
        }
    }

}

fileprivate extension Int {

    fileprivate func octalToDecimal() -> Int {
        var octal = self
        var decimal = 0, i = 0
        while octal != 0 {
            let remainder = octal % 10
            octal /= 10
            decimal += remainder * Int(pow(8, Double(i)))
            i += 1
        }
        return decimal
    }

    fileprivate func roundTo512() -> Int {
        let fractionNum = Double(self) / 512
        let roundedNum = Int(ceil(fractionNum))
        return roundedNum * 512
    }

}