import SwiftUI

struct FirmwareJourney: View {
    let stage: FirmwareModel.Stage
    let hasImage: Bool
    private var step: Int {
        switch stage { case .ready: 1; case .uploading, .installing: 2; case .reconnecting, .verified, .uncertain: 3; default: hasImage ? 1 : 0 }
    }
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(["检查版本", "准备文件", "上传安装", "核对版本"].enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(.caption.weight(.semibold)).frame(width: 25, height: 25)
                        .background(index == step ? Color.teal.opacity(0.12) : Color.secondary.opacity(0.07), in: Circle())
                    Text(title).font(.caption.weight(index == step ? .semibold : .regular))
                }.foregroundStyle(index == step ? Color.teal : .secondary)
                if index < 3 { Rectangle().fill(.quaternary).frame(maxWidth: 56).frame(height: 1) }
            }
        }.padding(.vertical, 3)
    }
}
