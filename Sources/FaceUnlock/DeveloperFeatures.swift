import Foundation

enum DeveloperFeatures {
    static var recognitionEvaluation: Bool { CommandLine.arguments.contains("--recognition-evaluation") }
}
