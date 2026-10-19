import Testing
@testable import OrbitCore

@Suite struct CompressPlanTests {
    @Test func percentIsPerFile() {
        let jobs = CompressPlan.jobs(for: .percentSmaller(60), sizes: [1_000_000, 10_000_000, 500_000])
        #expect(jobs.map(\.indices) == [[0], [1], [2]])
        #expect(jobs.map(\.target) == [.fitUnder(400_000), .fitUnder(4_000_000), .fitUnder(200_000)])
    }

    @Test func percentSkipsUnknownSizes() {
        let jobs = CompressPlan.jobs(for: .percentSmaller(50), sizes: [0, 2_000])
        #expect(jobs == [CompressPlan.Job(indices: [1], target: .fitUnder(1_000))])
    }

    @Test func absoluteSizeIsOneJobForAll() {
        let jobs = CompressPlan.jobs(for: .underBytes(2_000_000), sizes: [1, 2, 3])
        #expect(jobs == [CompressPlan.Job(indices: [0, 1, 2], target: .fitUnder(2_000_000))])
        #expect(CompressPlan.jobs(for: .underBytes(0), sizes: [1]).isEmpty)
        #expect(CompressPlan.jobs(for: .underBytes(10), sizes: []).isEmpty)
    }

    @Test func singleTarget() {
        #expect(CompressPlan.target(.percentSmaller(90), forBytes: 5) == .fitUnder(1))
        #expect(CompressPlan.target(.percentSmaller(50), forBytes: 0) == nil)
    }
}
