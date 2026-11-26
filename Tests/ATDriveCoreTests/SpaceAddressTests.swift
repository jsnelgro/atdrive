import Foundation
import Testing

@testable import ATDriveCore

/// A space's address in its two forms: ATDrive's (`at://<did>/space/<type>/<key>`, what it
/// stores and seals with) and the PDS's (`at:space/<did>/<type>/<key>`, what space parameters
/// take since Nov 2026).
@Suite struct SpaceAddressTests {
    let local = "at://did:plc:abc/space/app.atdrive.drive/default"
    let wire = "at:space/did:plc:abc/app.atdrive.drive/default"

    @Test func eitherFormReadsAsTheSameSpace() {
        for form in [local, wire] {
            let parts = XRPCClient.spaceParts(form)
            #expect(parts?.authority == "did:plc:abc")
            #expect(parts?.type == "app.atdrive.drive")
            #expect(parts?.key == "default")
        }
        #expect(XRPCClient.spaceURI(authority: "did:plc:abc", type: "app.atdrive.drive", key: "default") == local)
        #expect(XRPCClient.wireSpaceURI(authority: "did:plc:abc", type: "app.atdrive.drive", key: "default") == wire)
    }

    @Test func convertsBetweenTheForms() {
        #expect(XRPCClient.wire(local) == wire)
        #expect(XRPCClient.wire(wire) == wire)
        #expect(XRPCClient.local(wire) == local)
        #expect(XRPCClient.local(local) == local)
        // What isn't a space is left as it is.
        #expect(XRPCClient.wire("at://did:plc:abc/app.bsky.feed.post/1") == "at://did:plc:abc/app.bsky.feed.post/1")
        #expect(XRPCClient.local("nonsense") == "nonsense")
    }

    @Test func refusesWhatIsntASpace() {
        for bad in [
            "at://did:plc:abc/app.atdrive.drive/default", "at://alice.test/space/app.atdrive.drive/default",
            "at:space/alice.test/app.atdrive.drive/default", "at:space/did:plc:abc/app.atdrive.drive",
            "at:space/did:plc:abc/app.atdrive.drive/default/did:plc:abc/app.atdrive.node/1",
            "at:space/did:plc:abc//default", "https://example.com",
        ] {
            #expect(XRPCClient.spaceParts(bad) == nil, "\(bad)")
        }
    }

    /// The form ATDrive seals with is its own, whichever the PDS uses: a record sealed before
    /// still opens.
    @Test func sealingUsesATDrivesForm() throws {
        let keyring = Keyring(DriveKey())
        let sealed = try keyring.seal(["a": 1], space: local, collection: Lexicon.node, rkey: "r")
        let opened = try keyring.open(
            sealed, as: [String: Int].self, space: XRPCClient.local(wire), collection: Lexicon.node, rkey: "r")
        #expect(opened == ["a": 1])
    }
}
