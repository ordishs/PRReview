public enum GitHubError: Error, Equatable {
    case invalidURL(String)
    case commandFailed(exitCode: Int32, message: String)
    case decodingFailed(String)
}
