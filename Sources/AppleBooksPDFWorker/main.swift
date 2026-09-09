import AppleBooksCore
import Foundation

let invocation = PDFWorkerProtocol.run(requestHandle: .standardInput)
FileHandle.standardOutput.write(invocation.stdout)
if let code = invocation.stderrCode {
    FileHandle.standardError.write(Data((code + "\n").utf8))
}
