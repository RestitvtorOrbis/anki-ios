// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation

/// State machine for a single review session.
///
/// Drives the backend scheduling RPCs and renders card HTML via RenderExistingCard.
/// No mediasrv required — card HTML is injected directly into a WKWebView and
/// media files are served by the companion MediaSchemeHandler over anki-media://.
@MainActor
final class ReviewSession: ObservableObject {

    enum ReviewState {
        case loading
        case question(CardContext)
        case answer(CardContext)
        case congrats
        case error(String)
    }

    struct CardContext {
        let queuedCard: Anki_Scheduler_QueuedCards.QueuedCard
        let questionHTML: String
        let answerHTML: String
        let cardCSS: String
        let newCount: UInt32
        let learningCount: UInt32
        let reviewCount: UInt32
        let shownAt: Date
    }

    @Published private(set) var reviewState: ReviewState = .loading

    private let backend: BackendClient
    let deckId: Int64
    private var pendingQueue: [Anki_Scheduler_QueuedCards.QueuedCard] = []
    private var counts: (new: UInt32, learning: UInt32, review: UInt32) = (0, 0, 0)

    init(backend: BackendClient, deckId: Int64) {
        self.backend = backend
        self.deckId = deckId
    }

    func start() {
        Task { await refillThenAdvance() }
    }

    func showAnswer() {
        if case .question(let ctx) = reviewState {
            reviewState = .answer(ctx)
        }
    }

    /// `ease` is 1-4: Again / Hard / Good / Easy, matching the answer button labels.
    func answer(ease: Int) {
        guard case .answer(let ctx) = reviewState else { return }
        Task {
            do {
                let qc = ctx.queuedCard
                let newState = pickNewState(from: qc.states, ease: ease)
                let rating = Anki_Scheduler_CardAnswer.Rating(rawValue: ease - 1) ?? .good
                let elapsed = Date().timeIntervalSince(ctx.shownAt)
                let _: Anki_Collection_OpChanges = try backend.run(
                    service: AnkiServiceIndex.SchedulerService.service,
                    method: AnkiServiceIndex.SchedulerService.answerCard,
                    request: Anki_Scheduler_CardAnswer.with {
                        $0.cardID = qc.card.id
                        $0.currentState = qc.states.current
                        $0.newState = newState
                        $0.rating = rating
                        $0.answeredAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
                        $0.millisecondsTaken = UInt32(min(elapsed * 1000, 60_000))
                    })
                await refillThenAdvance()
            } catch {
                reviewState = .error(String(describing: error))
            }
        }
    }

    // MARK: - Private

    private func pickNewState(
        from states: Anki_Scheduler_SchedulingStates, ease: Int
    ) -> Anki_Scheduler_SchedulingState {
        switch ease {
        case 1: return states.again
        case 2: return states.hard
        case 4: return states.easy
        default: return states.good
        }
    }

    private func fetchQueue() throws {
        let queued: Anki_Scheduler_QueuedCards = try backend.run(
            service: AnkiServiceIndex.SchedulerService.service,
            method: AnkiServiceIndex.SchedulerService.getQueuedCards,
            request: Anki_Scheduler_GetQueuedCardsRequest.with {
                $0.fetchLimit = 3
                $0.intradayLearningOnly = false
            })
        pendingQueue = Array(queued.cards)
        counts = (queued.newCount, queued.learningCount, queued.reviewCount)
    }

    private func refillThenAdvance() async {
        do {
            if pendingQueue.isEmpty { try fetchQueue() }
            guard !pendingQueue.isEmpty else { reviewState = .congrats; return }

            let qc = pendingQueue.removeFirst()
            let rendered: Anki_CardRendering_RenderCardResponse = try backend.run(
                service: AnkiServiceIndex.CardRenderingService.service,
                method: AnkiServiceIndex.CardRenderingService.renderExistingCard,
                request: Anki_CardRendering_RenderExistingCardRequest.with {
                    $0.cardID = qc.card.id
                    $0.browser = false
                })
            let q = rendered.questionNodes.compactMap(\.textValue).joined()
            let a = rendered.answerNodes.compactMap(\.textValue).joined()
            reviewState = .question(CardContext(
                queuedCard: qc,
                questionHTML: q,
                answerHTML: a,
                cardCSS: rendered.css,
                newCount: counts.new,
                learningCount: counts.learning,
                reviewCount: counts.review,
                shownAt: Date()))

            // Eagerly prefetch the next batch while the user is looking at the card.
            if pendingQueue.isEmpty {
                Task { do { try fetchQueue() } catch {} }
            }
        } catch {
            reviewState = .error(String(describing: error))
        }
    }
}

// MARK: - Helpers

extension Anki_CardRendering_RenderedTemplateNode {
    /// Returns the text value if this node is a plain-text node; nil if it is a
    /// replacement placeholder (unknown filter). We join only text nodes so that
    /// an unfilled {{cloze}} placeholder does not appear as a raw proto field.
    var textValue: String? {
        if case .text(let t) = value { return t }
        return nil
    }
}
