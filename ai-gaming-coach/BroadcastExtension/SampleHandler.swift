import CoachCore
import ReplayKit

/// Entry point of the Broadcast Upload Extension (principal class in
/// Info.plist). iOS launches this process when the user picks
/// "AI Gaming Coach" in the system broadcast picker, and keeps it running
/// while any other app (Fortnite) is in the foreground.
///
/// ReplayKit calls these methods serially, so no locking is needed here.
final class SampleHandler: RPBroadcastSampleHandler {
    private var pipeline: BroadcastPipeline?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            pipeline = try BroadcastPipeline()
        } catch {
            // Ends the broadcast and shows the message to the user.
            finishBroadcastWithError(NSError(
                domain: "AIGamingCoach.Broadcast", code: 1,
                userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
            ))
        }
    }

    override func broadcastPaused() {
        pipeline?.pause()
    }

    override func broadcastResumed() {
        pipeline?.resume()
    }

    override func broadcastFinished() {
        pipeline?.finish()
        pipeline = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard let pipeline else { return }
        switch sampleBufferType {
        case .video:
            pipeline.handleVideo(sampleBuffer)
        case .audioApp:
            pipeline.handleAudio(.app)
        case .audioMic:
            pipeline.handleAudio(.microphone)
        @unknown default:
            break
        }
    }
}
