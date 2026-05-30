import 'package:flutter/foundation.dart';

class Signal<T> extends ChangeNotifier {
  T _value;

  Signal(this._value);

  T get value => _value;

  set value(T newValue) {
    if (_value != newValue) {
      _value = newValue;
      notifyListeners();
    }
  }
}

Listenable createListenableFromSignals(List<ChangeNotifier> signals) {
  return Listenable.merge(signals);
}
