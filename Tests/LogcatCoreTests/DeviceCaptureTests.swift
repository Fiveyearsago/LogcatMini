import XCTest
import ImageIO
import AVFoundation
@testable import LogcatCore

final class DeviceCaptureTests: XCTestCase {
    func testBinaryScreenshotAndRecordingsStayBoundToTheirDevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("logcat media tests " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adb = root.appendingPathComponent("fake adb"), recorder = root.appendingPathComponent("scrcpy")
        let script = #"""
        #!/usr/bin/env python3
        import sys, pathlib, json, time, base64, signal, os
        root=pathlib.Path(__file__).parent
        a=sys.argv[1:]
        with (root/'calls.jsonl').open('a') as f: f.write(json.dumps(a)+'\n')
        if a[0]=='-s':
            assert a[2:]==['exec-out','screencap','-p']
            if a[1]=='bad': sys.stdout.buffer.write(b'not a png');sys.exit(0)
            sys.stdout.buffer.write(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='))
        else:
            assert a[0]=='--serial' and '--no-control' in a and '--no-window' in a
            assert os.environ['ADB']==str(root/'fake adb')
            assert os.environ['SCRCPY_SERVER_PATH']==str(root/'scrcpy-server')
            out=pathlib.Path(next(s[len('--record='):] for s in a if s.startswith('--record=')))
            stopped=False
            def stop(*_):
                global stopped
                stopped=True
            signal.signal(signal.SIGINT,stop)
            (root/(a[1]+'.started')).touch()
            for _ in range(1000):
                if stopped: break
                time.sleep(.01)
            out.write_bytes(b'\x00\x00\x00\x18ftypmp42'+bytes(20))
        """#
        for executable in [adb, recorder] {
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let png = root.appendingPathComponent("截图 有空格.png")
        try await DeviceCapture.screenshot(path: adb.path, serial: "device-a", to: png)
        let original = try Data(contentsOf: png)
        XCTAssertEqual(Array(original.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        do { try await DeviceCapture.screenshot(path: adb.path, serial: "bad", to: png); XCTFail("invalid image accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: png), original, "Failed capture must preserve an existing file")
        let first = try AndroidScreenRecording(path: adb.path, serial: "device-a", runtime: root)
        let second = try AndroidScreenRecording(path: adb.path, serial: "device-b", runtime: root)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("device-b.started").path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await first.stop()
        do {
            try await first.saveWhenFinished(to: root.appendingPathComponent("missing directory/video.mp4"))
            XCTFail("Invalid destination accepted")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.temporaryMovie.path), "Retain video for retry")
        try await first.saveWhenFinished(to: root.appendingPathComponent("video a.mp4"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.temporaryMovie.path))
        XCTAssertTrue(second.isRunning, "Stopping A must not stop B")
        try await second.stop()
        let movie = root.appendingPathComponent("video b.mp4")
        try Data("old file".utf8).write(to: movie)
        try await second.saveWhenFinished(to: movie)
        XCTAssertEqual(String(data: try Data(contentsOf: movie)[4..<8], encoding: .ascii), "ftyp")
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        XCTAssertEqual(Set(calls.filter { $0.first == "--serial" }.map { $0[1] }), ["device-a", "device-b"])
    }

    func testRealDeviceScreenshotAndVideoWhenRequested() async throws {
        guard let serial = ProcessInfo.processInfo.environment["LOGCAT_MINI_CAPTURE_DEVICE"], let adb = ADB.locate(),
              let runtime = ProcessInfo.processInfo.environment["LOGCAT_MINI_RECORDER_RUNTIME"] else {
            throw XCTSkip("Set device serial and runtime path to explicitly enable physical-device capture QA")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("logcat-mini-device-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("screen.png"), movie = root.appendingPathComponent("screen.mp4")
        try await DeviceCapture.screenshot(path: adb, serial: serial, to: png)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertGreaterThan(properties[kCGImagePropertyPixelWidth] as? Int ?? 0, 0)
        let recording = try AndroidScreenRecording(path: adb, serial: serial, runtime: URL(fileURLWithPath: runtime))
        try await Task.sleep(nanoseconds: 5_000_000_000)
        try await recording.stop(); try await recording.saveWhenFinished(to: movie)
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration), tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 1)
        XCTAssertFalse(tracks.isEmpty)
        let generator = AVAssetImageGenerator(asset: asset)
        _ = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        print("Verified PNG and decoded MP4 on \(serial), duration \(CMTimeGetSeconds(duration)) seconds")
    }
}
