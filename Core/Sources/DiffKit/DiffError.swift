public enum DiffError: Error, Equatable {
    case gitFailed(exitCode: Int32, message: String)
}
