from pathlib import Path

path = Path("StrandiOS/Health/HealthKitBridge.swift")
text = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1, found {count}")
    text = text.replace(old, new, 1)


marker = "                                                             limit: Self.workoutReadLimit)\n        var sleepsByStart: [Int: CachedSleepSession] = [:]"
replace_once(
    marker,
    "                                                             limit: Self.workoutReadLimit)\n"
    "        // Snapshot only legacy device-scoped NOOP Health objects before ANY replacement writes.\n"
    "        // A failed query aborts the pass; an unread source is never treated as an empty source.\n"
    "        let stranded = try await captureStrandedHealthRecords(fromTs: fromTs, nowTs: nowTs)\n"
    "        var sleepsByStart: [Int: CachedSleepSession] = [:]",
    "legacy snapshot insertion",
)

old_start = "        // #1503: one-off sweep to clear records stranded under the OLD device-id-keyed scheme.\n"
old_call = "        await attempt { try await migrateStrandedHealthRecords(fromTs: fromTs, nowTs: nowTs) }\n"
if text.count(old_start) != 1 or text.count(old_call) != 1:
    raise SystemExit("old migration call block changed")
a = text.index(old_start)
b = text.index(old_call, a) + len(old_call)
text = (
    text[:a]
    + "        // #1503 legacy retirement is deferred until every current-key writer succeeds.\n"
    + "        // `stranded` contains only exact pre-write objects with the retired key shape.\n"
    + text[b:]
)

replace_once(
    "        if let firstError { throw firstError }\n    }\n\n    /// UserDefaults key for the #1503 stranded-records sweep completion set.",
    "        if let firstError { throw firstError }\n"
    "        // All current-key writes succeeded. Retire only the exact legacy objects captured above.\n"
    "        try await retireStrandedHealthRecords(stranded)\n"
    "    }\n\n    /// UserDefaults key for the #1503 stranded-records sweep completion set.",
    "legacy retirement insertion",
)

method_start = "    private func migrateStrandedHealthRecords(fromTs: Int, nowTs: Int) async throws {"
method_end = "\n    /// The nightly vitals write"
if text.count(method_start) != 1 or text.count(method_end) != 1:
    raise SystemExit("legacy migration method markers changed")
a = text.index(method_start)
b = text.index(method_end, a)
new_methods = '''    /// Capture only NOOP-authored objects carrying the retired device-scoped key shape.
    /// The source+date predicate bounds the read; metadata decides eligibility for retirement.
    private func captureStrandedHealthRecords(fromTs: Int, nowTs: Int) async throws -> [String: [HKSample]] {
        let defaults = UserDefaults.standard
        let swept = Set(defaults.stringArray(forKey: Self.strandedRecordsSweptKey) ?? [])
        let bySource = HKQuery.predicateForObjects(from: HKSource.default())
        let byDate = HKQuery.predicateForSamples(
            withStart: Date(timeIntervalSince1970: TimeInterval(fromTs)),
            end: Date(timeIntervalSince1970: TimeInterval(nowTs) + 60),
            options: [])
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, byDate])

        func legacyOnly(_ samples: [HKSample]) -> [HKSample] {
            samples.filter { sample in
                guard let key = sample.metadata?[HKMetadataKeyExternalUUID] as? String else { return false }
                return HealthWriteback.isLegacyDeviceScopedAppleHealthKey(key)
            }
        }

        var captured: [String: [HKSample]] = [:]
        for id in Self.quantityWriteIds {
            let typeId = id.rawValue
            guard !swept.contains(typeId),
                  let type = HKQuantityType.quantityType(forIdentifier: id),
                  store.authorizationStatus(for: type) == .sharingAuthorized else { continue }
            captured[typeId] = legacyOnly(try await ownSamples(type: type, predicate: pred))
        }
        if !swept.contains(Self.sleepSweepTypeId),
           let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
           store.authorizationStatus(for: sleep) == .sharingAuthorized {
            captured[Self.sleepSweepTypeId] = legacyOnly(try await ownSamples(type: sleep, predicate: pred))
        }
        if !swept.contains(Self.workoutSweepTypeId),
           store.authorizationStatus(for: .workoutType()) == .sharingAuthorized {
            captured[Self.workoutSweepTypeId] = legacyOnly(
                try await ownSamples(type: HKObjectType.workoutType(), predicate: pred))
        }
        return captured
    }

    /// Retire exact pre-write legacy objects only after the replacement pass succeeded.
    /// Completion is persisted per type, so a failed delete remains pending for a later retry.
    private func retireStrandedHealthRecords(_ captured: [String: [HKSample]]) async throws {
        guard !captured.isEmpty else { return }
        let defaults = UserDefaults.standard
        var swept = Set(defaults.stringArray(forKey: Self.strandedRecordsSweptKey) ?? [])
        for typeId in captured.keys.sorted() where !swept.contains(typeId) {
            let samples = captured[typeId] ?? []
            if !samples.isEmpty { try await store.delete(samples) }
            swept.insert(typeId)
            defaults.set(Array(swept).sorted(), forKey: Self.strandedRecordsSweptKey)
        }
    }
'''
text = text[:a] + new_methods + text[b:]

bykey_start = "        // Both source reads completed before any HealthKit deletion in this pass.\n        var byKey: [String: WorkoutRow] = [:]"
key_end = "        func key(_ row: WorkoutRow) -> String { HealthWriteback.appleHealthWorkoutKey(startTs: row.startTs) }\n"
if text.count(bykey_start) != 1 or text.count(key_end) != 1:
    raise SystemExit("workout canonicalization markers changed")
a = text.index(bykey_start)
b = text.index(key_end, a) + len(key_end)
canonical_block = '''        // Both source reads completed before any HealthKit deletion in this pass. Adapt each
        // persisted row into the SAME canonical representation the FIT exporter consumes. Keep the
        // existing mine-over-computed collision precedence by inserting computed first, mine second.
        var byKey: [String: CanonicalWorkout] = [:]
        for w in computed where w.source != HealthKitBridge.appleWorkoutSource {
            let canonical = CanonicalWorkout(workoutRow: w, deviceID: computedDeviceId)
            byKey["\(canonical.startTimestamp):\(canonical.sport)"] = canonical
        }
        for w in mine where w.source != HealthKitBridge.appleWorkoutSource {
            let canonical = CanonicalWorkout(workoutRow: w, deviceID: noopDeviceId)
            byKey["\(canonical.startTimestamp):\(canonical.sport)"] = canonical
        }
        let rows = byKey.values.sorted { $0.startTimestamp < $1.startTimestamp }

        func key(_ row: CanonicalWorkout) -> String {
            // Keep the established HealthKit reconciliation identity for backwards compatibility.
            HealthWriteback.appleHealthWorkoutKey(startTs: row.startTimestamp)
        }
'''
text = text[:a] + canonical_block + text[b:]

loop_start = "        for row in rows {\n            let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))\n"
loop_end = "        // Every replacement is now committed. Retire only the exact workout objects captured\n"
if text.count(loop_start) != 1 or text.count(loop_end) != 1:
    raise SystemExit("workout builder loop markers changed")
a = text.index(loop_start)
b = text.index(loop_end, a)
new_loop = '''        for row in rows {
            let start = Date(timeIntervalSince1970: TimeInterval(row.startTimestamp))
            let end = Date(timeIntervalSince1970: TimeInterval(row.endTimestamp))
            guard end > start else { continue }
            let config = HKWorkoutConfiguration()
            config.activityType = Self.activityType(forSport: row.sport)
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
            do {
                try await builder.beginCollection(at: start)
                try await builder.addMetadata([HKMetadataKeyExternalUUID: key(row)])
                var extras: [HKSample] = []
                if let kcal = row.energyKcal, kcal > 0,
                   let t = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                   store.authorizationStatus(for: t) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: t, quantity: .init(unit: .kilocalorie(), doubleValue: kcal),
                                                   start: start, end: end))
                }
                if let meters = row.distanceM, meters > 0,
                   let id = Self.distanceTypeId(forSport: row.sport),
                   let t = HKQuantityType.quantityType(forIdentifier: id),
                   store.authorizationStatus(for: t) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: t, quantity: .init(unit: .meter(), doubleValue: meters),
                                                   start: start, end: end))
                }
                if !extras.isEmpty { try await builder.addSamples(extras) }
                try await builder.endCollection(at: end)
                _ = try await builder.finishWorkout()
            } catch {
                builder.discardWorkout()
                throw error
            }
        }
'''
text = text[:a] + new_loop + text[b:]
path.write_text(text)
