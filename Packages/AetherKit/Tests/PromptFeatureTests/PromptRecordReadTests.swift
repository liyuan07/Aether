// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import Darwin
import CAetherCore
import RustCore
@testable import PromptFeature

/// Frozen 550038b reader: Rust domain validation/serialization followed by Foundation DTO decoding.
private final class ReferencePromptReader {
    private let lock = NSRecursiveLock()
    private let core: UnsafeMutableRawPointer?
    init(directory: URL) throws {
        let fallback = try JSONEncoder().encode(PromptConfiguration())
        core = directory.withUnsafeFileSystemRepresentation { path in
            fallback.withUnsafeBytes { aether_prompt_store_create(path,.init(data:$0.bindMemory(to:UInt8.self).baseAddress,length:$0.count)) }
        }
    }
    deinit { aether_prompt_store_destroy(core) }
    func load<T: Decodable>(_ type: T.Type, slot: UInt32) throws -> T {
        lock.lock(); defer { lock.unlock() }
        do { return try JSONDecoder().decode(type,from:RustBuffer.take(aether_prompt_store_load(core,slot))) }
        catch let error as RustDiskError {
            switch error.status {
            case 4: throw PromptStorageError.unsupportedVersion
            case 5: throw PromptStorageError.invalidConfiguration
            default: throw PromptStorageError.unreadable
            }
        } catch { throw PromptStorageError.unreadable }
    }
}
private struct RecordEnvelope<T: Codable>: Codable {
    let schemaVersion: Int
    let payload: T
    init(payload: T) { schemaVersion = 1; self.payload = payload }
}
private struct RecordContext {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherPromptRecords-\(UUID())")
    func put(_ bytes: Data, name: String) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try bytes.write(to:root.appendingPathComponent(name))
    }
    func cleanup() { try? FileManager.default.removeItem(at:root) }
}
private func recordFixture(_ count: Int, large: Bool = false) -> [PromptHistoryEntry] {
    let texts = ["", "合成\u{0000}👩‍💻e\u{301}", "\\\"\r\n\t", "á a\u{301}", "🧪 中文"]
    let dates: [Double] = [-0.0,0,Double.leastNonzeroMagnitude,Double.leastNormalMagnitude,-Double.leastNormalMagnitude,-987654321.1234567,812345678.9876543,Double.greatestFiniteMagnitude]
    let extra = large ? String(repeating:"abc中文",count:512) : ""
    return (0..<count).map { index in
        PromptHistoryEntry(id:UUID(uuidString:String(format:"00000000-0000-0000-0000-%012x",index+1))!,
            createdAt:Date(timeIntervalSinceReferenceDate:dates[index % dates.count]),
            original:texts[index % texts.count]+extra,optimized:texts[(index+1) % texts.count]+extra,model:texts[(index+2) % texts.count])
    }
}

final class PromptRecordReadTests: XCTestCase {
    func testEveryHistoryFieldMatchesNativeEnvelopeAndFrozenReaderAfterOwnersExpire() throws {
        let context=RecordContext(); defer {context.cleanup()}
        let expected=recordFixture(1024)
        let bytes=try JSONEncoder().encode(RecordEnvelope(payload:expected))
        try context.put(bytes,name:"history.json")
        let native=try JSONDecoder().decode(RecordEnvelope<[PromptHistoryEntry]>.self,from:bytes).payload
        let legacy=try ReferencePromptReader(directory:context.root).load([PromptHistoryEntry].self,slot:1)
        var storage: PromptStorage?=PromptStorage(directory:context.root)
        let actual=try XCTUnwrap(storage).loadHistory()
        storage=nil
        try context.put(Data("{ synthetic changed file}".utf8),name:"history.json")
        // The Rust snapshot and its store have both been destroyed by this point.
        XCTAssertEqual(actual.count,native.count); XCTAssertEqual(actual.count,legacy.count)
        for index in actual.indices {
            XCTAssertEqual(actual[index].id,native[index].id)
            XCTAssertEqual(actual[index].createdAt.timeIntervalSinceReferenceDate.bitPattern,legacy[index].createdAt.timeIntervalSinceReferenceDate.bitPattern,"date bits at \(index)")
            for (a,b,c) in [(actual[index].original,native[index].original,legacy[index].original),
                            (actual[index].optimized,native[index].optimized,legacy[index].optimized),
                            (actual[index].model,native[index].model,legacy[index].model)] {
                XCTAssertTrue(a.utf8.elementsEqual(b.utf8)); XCTAssertTrue(a.utf8.elementsEqual(c.utf8))
            }
        }
    }
    func testConfigurationNilEmptyAndUnicodeValuesMatchIndependentNativeDecode() throws {
        let context=RecordContext(); defer {context.cleanup()}
        for fingerprint: String? in [nil,"","合成\u{0000}e\u{301}"] {
            for enabled in [false,true] { for limit in [1,200,1000] {
                let expected=PromptConfiguration(baseURL:" \u{0000}synthetic://e\u{301} ",model:"",systemPrompt:"合成👩‍💻\r\n",saveHistory:enabled,historyLimit:limit,credentialFingerprint:fingerprint)
                let bytes=try JSONEncoder().encode(RecordEnvelope(payload:expected))
                try context.put(bytes,name:"configuration.json")
                let native=try JSONDecoder().decode(RecordEnvelope<PromptConfiguration>.self,from:bytes).payload
                let old=try ReferencePromptReader(directory:context.root).load(PromptConfiguration.self,slot:0)
                let actual=try PromptStorage(directory:context.root).loadConfiguration()
                XCTAssertEqual(actual,native); XCTAssertEqual(actual,old)
                XCTAssertEqual(actual.credentialFingerprint == nil,fingerprint == nil)
                XCTAssertTrue(actual.baseURL.utf8.elementsEqual(native.baseURL.utf8))
                XCTAssertTrue(actual.systemPrompt.utf8.elementsEqual(native.systemPrompt.utf8))
                XCTAssertEqual(try Data(contentsOf:context.root.appendingPathComponent("configuration.json")),bytes)
            }}
        }
    }
    func testErrorsMatchFrozenReaderAndNeverRewriteMalformedOrFutureFiles() throws {
        let fixtures:[(String,UInt32)]=[("{invalid",0),("{invalid",1),
            (#"{"schemaVersion":99,"payload":{}}"#,0),(#"{"schemaVersion":99,"payload":[]}"#,1),
            (#"{"schemaVersion":1,"payload":null}"#,0),(#"{"schemaVersion":1,"payload":null}"#,1),
            (#"{"schemaVersion":1,"payload":[{"id":"bad","createdAt":0,"original":"x","optimized":"y","model":"z"}]}"#,1)]
        for (source,slot) in fixtures {
            let context=RecordContext(); defer {context.cleanup()}
            let name=slot==0 ? "configuration.json" : "history.json"
            let bytes=Data(source.utf8);try context.put(bytes,name:name)
            let old=try ReferencePromptReader(directory:context.root),current=PromptStorage(directory:context.root)
            func message(_ body:() throws -> Void) -> String? {do {try body();return nil}catch{return error.localizedDescription}}
            let expected=message {if slot==0 {_=try old.load(PromptConfiguration.self,slot:slot)}else{_=try old.load([PromptHistoryEntry].self,slot:slot)}}
            let actual=message {if slot==0 {_=try current.loadConfiguration()}else{_=try current.loadHistory()}}
            XCTAssertNotNil(expected);XCTAssertEqual(actual,expected)
            if slot==0 {XCTAssertThrowsError(try current.saveConfiguration(.init()))}else{XCTAssertThrowsError(try current.saveHistory([]))}
            XCTAssertEqual(try Data(contentsOf:context.root.appendingPathComponent(name)),bytes)
        }
    }
    func testReturnedHistoryLiveAllocationBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_PROMPT_RECORD_BENCHMARK"]=="1" else {throw XCTSkip("Explicit synthetic live allocation benchmark")}
        let context=RecordContext();defer{context.cleanup()}
        let input=try JSONEncoder().encode(RecordEnvelope(payload:recordFixture(1000,large:true)))
        try context.put(input,name:"history.json")
        let old=try ReferencePromptReader(directory:context.root),current=PromptStorage(directory:context.root)
        func stats() -> malloc_statistics_t {var value=malloc_statistics_t();malloc_zone_statistics(nil,&value);return value}
        var bytes=[[Int](),[Int]()],blocks=[[Int](),[Int]()]
        for round in 0..<8 {for backend in round.isMultiple(of:2) ? [0,1] : [1,0] {
            let sample: (Int,Int)=try autoreleasepool {
                let before=stats()
                let rows=try autoreleasepool {backend==0 ? try old.load([PromptHistoryEntry].self,slot:1) : try current.loadHistory()}
                let after=withExtendedLifetime(rows){stats()}
                XCTAssertEqual(rows.count,1000)
                return (Int(after.size_in_use)-Int(before.size_in_use),Int(after.blocks_in_use)-Int(before.blocks_in_use))
            }
            if round>0 {bytes[backend].append(sample.0);blocks[backend].append(sample.1)}
        }}
        let result:[String:Any]=["items":1000,"input_bytes":input.count,"old_live_bytes":bytes[0],"new_live_bytes":bytes[1],"old_median_live_bytes":bytes[0].sorted()[3],"new_median_live_bytes":bytes[1].sorted()[3],"old_median_live_blocks":blocks[0].sorted()[3],"new_median_live_blocks":blocks[1].sorted()[3]]
        print("PROMPT_RECORD_ALLOCATIONS "+String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
    func testDirectRecordReleaseBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_PROMPT_RECORD_BENCHMARK"]=="1" else {throw XCTSkip("Explicit synthetic Release benchmark")}
        let context=RecordContext();defer{context.cleanup()}
        let fixture=recordFixture(1000,large:true)
        let input=try JSONEncoder().encode(RecordEnvelope(payload:fixture));try context.put(input,name:"history.json")
        let old=try ReferencePromptReader(directory:context.root),current=PromptStorage(directory:context.root)
        func load(_ backend:Int) throws -> [PromptHistoryEntry] {backend==0 ? try old.load([PromptHistoryEntry].self,slot:1) : try current.loadHistory()}
        for backend in [0,1] {_=try autoreleasepool{try load(backend)}}
        var times=[[Double](),[Double]()]
        for round in 0..<7 {for backend in round.isMultiple(of:2) ? [0,1] : [1,0] {
            let start=DispatchTime.now().uptimeNanoseconds
            var count=0
            for _ in 0..<5 {count += try autoreleasepool{try load(backend).count}}
            let elapsed=Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
            times[backend].append(elapsed)
            XCTAssertEqual(count,5000)
            let actual=try load(backend);XCTAssertEqual(actual,fixture)
            XCTAssertEqual(try Data(contentsOf:context.root.appendingPathComponent("history.json")),input)
        }}
        let result:[String:Any]=["items":1000,"input_bytes":input.count,"operations_per_round":5,"old_ms":times[0],"new_ms":times[1],"old_median_ms":times[0].sorted()[3],"new_median_ms":times[1].sorted()[3]]
        print("PROMPT_RECORD_BENCHMARK "+String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
}
