import AppKit
import ThreadbearCore

/// A review remains a compact card even after answering, so its images and
/// decision can be reopened without finding an old tool invocation.
final class ReviewRowCell: RowCellView {
    private let card = FillView()
    private let icon = Symbols.makeView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let open = PillButton(pill: "Compare images")
    private var review: DesignReview?

    override init(frame: NSRect) {
        super.init(frame: frame)
        [card, icon, title, detail, open].forEach(addSubview)
        open.target = self
        open.action = #selector(clicked)
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
    }
    required init?(coder: NSCoder) { fatalError() }

    override func configure(row: TranscriptRow, render: RowRender, tableWidth: CGFloat, expanded: Bool) {
        super.configure(row: row, render: render, tableWidth: tableWidth, expanded: expanded)
        guard case .review(let review) = row.content else { return }
        self.review = review
        let (x, width) = RowMetrics.column(for: row, tableWidth: tableWidth)
        let pad = RowMetrics.cardPad
        let top = RowMetrics.rowTop
        card.frame = NSRect(x: x, y: top, width: width, height: render.height - RowMetrics.rowTop - RowMetrics.rowBottom)
        card.set(fill: Theme.cardBackground, stroke: Theme.cardBorder, radius: RowMetrics.cardRadius, accent: review.isPending ? .systemOrange : nil)
        title.font = .systemFont(ofSize: TypeScale.work, weight: .semibold)
        title.stringValue = review.title
        // The feature's icon, also on the answer bubble and the panel's tab.
        Symbols.set(icon, Symbols.review, size: 13, tint: .secondaryLabelColor)
        icon.frame = NSRect(x: x + pad, y: top + pad, width: zoomed(18), height: zoomed(22))
        title.frame = NSRect(x: icon.frame.maxX + zoomed(6), y: top + pad, width: width - pad * 2 - zoomed(24), height: zoomed(22))
        detail.font = Theme.detailFont
        detail.textColor = Theme.quietText
        let picked = review.options.first { $0.id == review.response?.pickedId }
        let state = review.isPending ? "Waiting for your review" : review.status == "answered" ? picked.map { "Picked \($0.id). \($0.title)" } ?? "Notes sent" : review.status == "superseded" ? "Answered in the thread" : "Review closed"
        detail.stringValue = "\(review.options.count) images · \(state)"
        detail.frame = NSRect(x: x + pad, y: title.frame.maxY + zoomed(4), width: width - pad * 2, height: zoomed(20))
        open.title = review.isPending ? "Compare \(review.options.count) images" : "Open review"
        open.sizeToFit()
        open.frame = NSRect(x: x + pad, y: detail.frame.maxY + zoomed(10), width: max(zoomed(140), open.frame.width + zoomed(18)), height: RowMetrics.buttonHeight)
    }

    @objc private func clicked() { if let review { delegate?.openReview(review) } }
}
