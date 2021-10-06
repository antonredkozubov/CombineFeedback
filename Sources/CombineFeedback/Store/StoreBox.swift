import Combine
import CasePaths
import SwiftUI

internal class RootStoreBox<State, Event>: StoreBoxBase<State, Event> {
  private let subject: CurrentValueSubject<State, Never>

  private let inputObserver: (Update) -> Void
  private var bag = Set<AnyCancellable>()

  override var _current: State {
    subject.value
  }

  override var publisher: AnyPublisher<State, Never> {
    subject.eraseToAnyPublisher()
  }

  public init<Dependency>(
    initial: State,
    feedbacks: [Feedback<State, Event, Dependency>],
    reducer: Reducer<State, Event>,
    dependency: Dependency
  ) {
    let input = Feedback<State, Update, Dependency>.input
    self.subject = CurrentValueSubject(initial)
    self.inputObserver = input.observer
    Publishers.FeedbackLoop(
      initial: initial,
      reduce: .init { state, update in
        switch update {
        case .event(let event):
          reducer(&state, event)
        case .mutation(let mutation):
          mutation.mutate(&state)
        }
      },
      feedbacks: feedbacks.map {
        $0.pullback(value: \.self, event: /Update.event, dependency: { _ in dependency })
      }
      .appending(input.feedback),
      dependency: dependency
    )
    .sink(receiveValue: { [subject] state in
      subject.send(state)
    })
    .store(in: &bag)
  }

  override func send(event: Event) {
    self.inputObserver(.event(event))
  }

  override func mutate<V>(keyPath: WritableKeyPath<State, V>, value: V) {
    self.inputObserver(.mutation(Mutation(keyPath: keyPath, value: value)))
  }

  override func mutate(with mutation: Mutation<State>) {
    self.inputObserver(.mutation(mutation))
  }

  override func scoped<S, E>(getValue: @escaping (State) -> S, setValue: @escaping (inout State, S) -> Void, event: @escaping (E) -> Event) -> StoreBoxBase<S, E> {
    ScopedStoreBox<State, Event, S, E>(
      parent: self,
      getValue: getValue,
      setValue: setValue,
      event: event
    )
  }

  private enum Update {
    case event(Event)
    case mutation(Mutation<State>)
  }
}

internal class ScopedStoreBox<RootState, RootEvent, ScopedState, ScopedEvent>: StoreBoxBase<ScopedState, ScopedEvent> {
  private let parent: StoreBoxBase<RootState, RootEvent>
  private let getValue: (RootState) -> ScopedState
  private let setValue: (inout RootState, ScopedState) -> Void
  private let eventTransform: (ScopedEvent) -> RootEvent

  override var _current: ScopedState {
    getValue(parent._current)
  }

  override var publisher: AnyPublisher<ScopedState, Never> {
    parent.publisher.map(getValue).eraseToAnyPublisher()
  }

  init(
    parent: StoreBoxBase<RootState, RootEvent>,
    getValue: @escaping (RootState) -> ScopedState,
    setValue: @escaping (inout RootState, ScopedState) -> Void,
    event: @escaping (ScopedEvent) -> RootEvent
  ) {
    self.parent = parent
    self.getValue = getValue
    self.setValue = setValue
    self.eventTransform = event
  }

  override func send(event: ScopedEvent) {
    parent.send(event: eventTransform(event))
  }

  override func mutate(with mutation: Mutation<ScopedState>) {
    parent.mutate(with: Mutation<RootState>(mutate: { [getValue, setValue] rootState in
      var scopedState = getValue(rootState)
      mutation.mutate(&scopedState)
      setValue(&rootState, scopedState)
    }))
  }

  override func mutate<V>(keyPath: WritableKeyPath<ScopedState, V>, value: V) {
    mutate(with: Mutation(keyPath: keyPath, value: value))
  }

  override func scoped<S, E>(
    getValue: @escaping (ScopedState) -> S,
    setValue: @escaping (inout ScopedState, S) -> Void,
    event: @escaping (E) -> ScopedEvent
  ) -> StoreBoxBase<S, E> {
    ScopedStoreBox<RootState, RootEvent, S, E>(
      parent: self.parent) { rootState in
        getValue(self.getValue(rootState))
      } setValue: { rootState, s in
        /*
         struct RootState {
          var scopedState: ScopedState
         }
         struct ScopedState {
          var scopedState: S
         }
         */
        var scopedState = self.getValue(rootState)
        setValue(&scopedState, s)
        self.setValue(&rootState, scopedState)
      } event: { e in
        self.eventTransform(event(e))
      }
  }
}

internal class StoreBoxBase<State, Event> {
  /// Loop Internal SPI
  var _current: State { subclassMustImplement() }

  var publisher: AnyPublisher<State, Never> { subclassMustImplement() }

  func send(event: Event) {
    subclassMustImplement()
  }

  func mutate<V>(keyPath: WritableKeyPath<State, V>, value: V) {
    subclassMustImplement()
  }

  func mutate(with mutation: Mutation<State>) {
    subclassMustImplement()
  }

  final func scoped<S, E>(
    to scope: WritableKeyPath<State, S>,
    event: @escaping (E) -> Event
  ) -> StoreBoxBase<S, E> {
    self.scoped(
      getValue: { state in
        return state[keyPath: scope]
      },
      setValue: { state, scopedState in
        state[keyPath: scope] = scopedState
      },
      event: event
    )
  }

  func scoped<S, E>(
    getValue: @escaping (State) -> S,
    setValue: @escaping (inout State, S) -> Void,
    event: @escaping (E) -> Event
  ) -> StoreBoxBase<S, E> {
    subclassMustImplement()
  }
}

@inline(never)
private func subclassMustImplement(function: StaticString = #function) -> Never {
  fatalError("Subclass must implement `\(function)`.")
}
