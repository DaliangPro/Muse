import Foundation
import XCTest
@testable import Muse

final class AliyunASRClientTests: XCTestCase {
    func testClientStreamsPCMAndPublishesFinalTranscript() async throws {
        let socket = ScriptedAliyunWebSocketTask()
        let dialSpy = AliyunDialFactorySpy(socket: socket)
        let client = AliyunASRClient { request, configuration in
            dialSpy.make(request: request, configuration: configuration)
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: [
            "apiKey": "sk-test",
            "workspaceId": "llm-test123",
        ]))

        try await client.connect(config: config)

        let request = try XCTUnwrap(dialSpy.request)
        XCTAssertEqual(
            request.url?.absoluteString,
            "wss://llm-test123.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-WorkSpace"), "llm-test123")

        var iterator = await client.events.makeAsyncIterator()
        let audio = Data([0x01, 0x02, 0x03, 0x04])
        try await client.sendAudio(audio)
        XCTAssertEqual(socket.sentBinaryMessages, [audio])

        let taskID = try XCTUnwrap(socket.taskID)
        socket.yieldServerMessage(resultMessage(taskID: taskID, text: "你好", isFinal: false))
        let partialEvent = await iterator.next()
        guard case .transcript(let partial)? = partialEvent else {
            return XCTFail("应收到阿里云流式中间结果")
        }
        XCTAssertEqual(partial.partialText, "你好")
        XCTAssertEqual(partial.composedText, "你好")

        socket.yieldServerMessage(resultMessage(taskID: taskID, text: "你好，世界。", isFinal: true))
        let sentenceEvent = await iterator.next()
        guard case .transcript(let sentence)? = sentenceEvent else {
            return XCTFail("应收到阿里云句末结果")
        }
        XCTAssertEqual(sentence.confirmedSegments, ["你好，世界。"])
        XCTAssertFalse(sentence.isFinal)

        try await client.endAudio()
        XCTAssertEqual(socket.sentActions.last, "finish-task")
        socket.yieldServerMessage(taskFinishedMessage(taskID: taskID))

        let finalEvent = await iterator.next()
        guard case .transcript(let finalTranscript)? = finalEvent else {
            return XCTFail("任务结束时应收到最终转写")
        }
        XCTAssertEqual(finalTranscript.authoritativeText, "你好，世界。")
        XCTAssertTrue(finalTranscript.isFinal)

        guard case .completed? = await iterator.next() else {
            return XCTFail("最终转写后应关闭事件流")
        }
        let streamEnd = await iterator.next()
        XCTAssertNil(streamEnd)
    }

    func testConnectSurfacesTaskFailure() async throws {
        let socket = ScriptedAliyunWebSocketTask(
            handshakeFailure: (code: "InvalidApiKey", message: "invalid api key")
        )
        let client = AliyunASRClient { _, _ in
            AliyunDialResources(task: socket, invalidateSession: {})
        }
        let config = try XCTUnwrap(AliyunASRConfig(credentials: ["apiKey": "sk-test"]))

        do {
            try await client.connect(config: config)
            XCTFail("鉴权失败时 connect 应抛错")
        } catch let error as AliyunASRError {
            XCTAssertEqual(
                error,
                .taskFailed(code: "InvalidApiKey", message: "invalid api key")
            )
        }
    }

    private func resultMessage(taskID: String, text: String, isFinal: Bool) -> String {
        """
        {
          "header": {"task_id": "\(taskID)", "event": "result-generated"},
          "payload": {"output": {"sentence": {
            "text": "\(text)", "sentence_end": \(isFinal), "heartbeat": false
          }}}
        }
        """
    }

    private func taskFinishedMessage(taskID: String) -> String {
        """
        {
          "header": {"task_id": "\(taskID)", "event": "task-finished"},
          "payload": {"output": {}, "usage": null}
        }
        """
    }
}

private final class AliyunDialFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private let socket: ScriptedAliyunWebSocketTask
    private var storedRequest: URLRequest?

    init(socket: ScriptedAliyunWebSocketTask) {
        self.socket = socket
    }

    var request: URLRequest? { lock.withLock { storedRequest } }

    func make(
        request: URLRequest,
        configuration: URLSessionConfiguration
    ) -> AliyunDialResources {
        _ = configuration
        lock.withLock { storedRequest = request }
        return AliyunDialResources(task: socket, invalidateSession: {})
    }
}

private final class ScriptedAliyunWebSocketTask: AliyunWebSocketTasking, @unchecked Sendable {
    private typealias ReceiveContinuation = CheckedContinuation<
        URLSessionWebSocketTask.Message,
        any Error
    >

    private let lock = NSLock()
    private let handshakeFailure: (code: String, message: String)?
    private var queuedMessages: [URLSessionWebSocketTask.Message] = []
    private var receiveContinuation: ReceiveContinuation?
    private var storedTaskID: String?
    private var storedSentActions: [String] = []
    private var storedBinaryMessages: [Data] = []

    init(handshakeFailure: (code: String, message: String)? = nil) {
        self.handshakeFailure = handshakeFailure
    }

    var taskID: String? { lock.withLock { storedTaskID } }
    var sentActions: [String] { lock.withLock { storedSentActions } }
    var sentBinaryMessages: [Data] { lock.withLock { storedBinaryMessages } }

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case .data(let data):
            lock.withLock { storedBinaryMessages.append(data) }
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let header = root["header"] as? [String: Any],
                  let action = header["action"] as? String,
                  let taskID = header["task_id"] as? String
            else { throw AliyunASRProtocolError.invalidMessage }

            lock.withLock {
                storedTaskID = taskID
                storedSentActions.append(action)
            }
            if action == "run-task" {
                if let handshakeFailure {
                    yieldServerMessage("""
                    {
                      "header": {
                        "task_id": "\(taskID)", "event": "task-failed",
                        "error_code": "\(handshakeFailure.code)",
                        "error_message": "\(handshakeFailure.message)"
                      },
                      "payload": {}
                    }
                    """)
                } else {
                    yieldServerMessage("""
                    {
                      "header": {"task_id": "\(taskID)", "event": "task-started"},
                      "payload": {}
                    }
                    """)
                }
            }
        @unknown default:
            throw AliyunASRProtocolError.invalidMessage
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> URLSessionWebSocketTask.Message? in
                if !queuedMessages.isEmpty {
                    return queuedMessages.removeFirst()
                }
                receiveContinuation = continuation
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        _ = closeCode
        _ = reason
        let continuation = lock.withLock { () -> ReceiveContinuation? in
            defer { receiveContinuation = nil }
            return receiveContinuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func yieldServerMessage(_ text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        let continuation = lock.withLock { () -> ReceiveContinuation? in
            guard let continuation = receiveContinuation else {
                queuedMessages.append(message)
                return nil
            }
            receiveContinuation = nil
            return continuation
        }
        continuation?.resume(returning: message)
    }
}
