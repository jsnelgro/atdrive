import Foundation
import Testing

@testable import ATDriveCore

@Suite struct EncodingTests {
    // Expected values computed independently with Python's hashlib + base64.
    @Test func blobCIDs() {
        #expect(CID.forBlob(Data()) == "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
        #expect(CID.forBlob(Data("hello world".utf8)) == "bafkreifzjut3te2nhyekklss27nh3k72ysco7y32koao5eei66wof36n5e")
    }

    @Test func tidsAreValidAndIncreasing() {
        var previous = TID.next()
        #expect(previous.count == 13)
        #expect(TID.isValid(previous))
        for _ in 0..<1000 {
            let next = TID.next()
            #expect(next > previous)
            previous = next
        }
    }

    @Test func tidValidation() {
        #expect(TID.isValid("3jzfcijpj2z2a"))
        #expect(!TID.isValid("3jzfcijpj2z2"))  // too short
        #expect(!TID.isValid("zjzfcijpj2z2a"))  // high bit set
        #expect(!TID.isValid("3jzfcijpj2z2A"))  // uppercase
        #expect(TID.encode(0, length: 2) == "22")
        #expect(TID.encode(1023, length: 2) == "zz")
    }
}

@Suite struct RecordTests {
    @Test func blobRefJSON() throws {
        let ref = BlobRef(cid: "bafkreiabc", mimeType: "application/octet-stream", size: 3)
        let object = try JSONSerialization.jsonObject(with: XRPCClient.encoder.encode(ref)) as! [String: Any]
        #expect(object["$type"] as? String == "blob")
        #expect((object["ref"] as? [String: Any])?["$link"] as? String == "bafkreiabc")
        #expect(try JSONDecoder().decode(BlobRef.self, from: XRPCClient.encoder.encode(ref)) == ref)
    }

    @Test func folderRecordOmitsFileFields() throws {
        let record = NodeRecord(name: "Docs", parent: nil, kind: .folder)
        let object = try JSONSerialization.jsonObject(with: XRPCClient.encoder.encode(record)) as! [String: Any]
        #expect(object["$type"] as? String == "me.jsnelgro.atdrive.node")
        #expect(Set(object.keys) == ["$type", "name", "kind", "createdAt"])
        #expect(try JSONDecoder().decode(NodeRecord.self, from: XRPCClient.encoder.encode(record)) == record)
    }

    @Test func timestampsRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        let record = NodeRecord(name: "a", parent: nil, kind: .file, createdAt: date, modifiedAt: date)
        #expect(abs(record.modifiedDate!.timeIntervalSince(date)) < 0.001)
        #expect(Timestamp.parse("2026-11-08T22:19:00Z") != nil)
    }

    @Test func drivePaths() throws {
        #expect(DrivePath("/a/./b/../c/").components == ["a", "c"])
        #expect(DrivePath("a/b").description == "/a/b")
        #expect(DrivePath("/").isRoot)
        #expect(DrivePath("/../..").isRoot)
        #expect(DrivePath("/a/b").parent == DrivePath("/a"))
        #expect(throws: ATDriveError.self) { try DrivePath.validate(name: "..") }
        #expect(throws: ATDriveError.self) { try DrivePath.validate(name: "") }
        #expect(throws: ATDriveError.self) { try DrivePath.validate(name: "a/b") }
        try DrivePath.validate(name: "résumé (final).pdf")
    }
}
