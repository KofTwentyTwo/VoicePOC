import Foundation

/// Paths to the three ONNX models in the openWakeWord pipeline.
public struct HeyJarvisModel {
    public let melspectrogramURL: URL
    public let embeddingURL: URL
    public let classifierURL: URL

    public init(modelsDirectory: URL = URL(fileURLWithPath: "Resources/models/openWakeWord")) throws {
        self.melspectrogramURL = modelsDirectory.appending(path: "melspectrogram.onnx")
        self.embeddingURL      = modelsDirectory.appending(path: "embedding_model.onnx")
        self.classifierURL     = modelsDirectory.appending(path: "hey_jarvis_v0.1.onnx")

        for url in [melspectrogramURL, embeddingURL, classifierURL] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VoicePOCError.modelFileMissing(url.path)
            }
        }
    }
}
