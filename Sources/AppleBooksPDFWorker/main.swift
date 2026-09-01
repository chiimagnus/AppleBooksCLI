import AppleBooksCore
import Foundation

let requestData = FileHandle.standardInput.readDataToEndOfFile()
let invocation = PDFWorkerProtocol.run(requestData: requestData)
FileHandle.standardOutput.write(invocation.stdout)
if let code = invocation.stderrCode {
    FileHandle.standardError.write(Data((code + "\n").utf8))
}
