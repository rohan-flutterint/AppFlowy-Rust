import 'dart:collection';
import 'dart:math';

import 'package:flowy_editor/src/document/attributes.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import './attributes.dart';

// constant number: 2^53 - 1
const int _maxInt = 9007199254740991;

abstract class TextOperation {
  bool get isEmpty => length == 0;

  int get length;

  Attributes? get attributes => null;

  Map<String, dynamic> toJson();
}

class TextInsert extends TextOperation {
  String content;
  final Attributes? _attributes;

  TextInsert(this.content, [Attributes? attrs]) : _attributes = attrs;

  @override
  int get length {
    return content.length;
  }

  @override
  Attributes? get attributes {
    return _attributes;
  }

  @override
  bool operator ==(Object other) {
    if (other is! TextInsert) {
      return false;
    }
    return content == other.content &&
        mapEquals(_attributes, other._attributes);
  }

  @override
  int get hashCode {
    final contentHash = content.hashCode;
    final attrs = _attributes;
    return Object.hash(
        contentHash, attrs == null ? null : hashAttributes(attrs));
  }

  @override
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'insert': content,
    };
    final attrs = _attributes;
    if (attrs != null) {
      result['attributes'] = {...attrs};
    }
    return result;
  }
}

class TextRetain extends TextOperation {
  int _length;
  final Attributes? _attributes;

  TextRetain(length, [Attributes? attributes])
      : _length = length,
        _attributes = attributes;

  @override
  bool get isEmpty {
    return length == 0;
  }

  @override
  int get length {
    return _length;
  }

  set length(int v) {
    _length = v;
  }

  @override
  Attributes? get attributes {
    return _attributes;
  }

  @override
  bool operator ==(Object other) {
    if (other is! TextRetain) {
      return false;
    }
    return _length == other.length && mapEquals(_attributes, other._attributes);
  }

  @override
  int get hashCode {
    final attrs = _attributes;
    return Object.hash(_length, attrs == null ? null : hashAttributes(attrs));
  }

  @override
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'retain': _length,
    };
    final attrs = _attributes;
    if (attrs != null) {
      result['attributes'] = {...attrs};
    }
    return result;
  }
}

class TextDelete extends TextOperation {
  int _length;

  TextDelete(int length) : _length = length;

  @override
  int get length {
    return _length;
  }

  set length(int v) {
    _length = v;
  }

  @override
  bool operator ==(Object other) {
    if (other is! TextDelete) {
      return false;
    }
    return _length == other.length;
  }

  @override
  int get hashCode {
    return _length.hashCode;
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'delete': _length,
    };
  }
}

class _OpIterator {
  final UnmodifiableListView<TextOperation> _operations;
  int _index = 0;
  int _offset = 0;

  _OpIterator(List<TextOperation> operations)
      : _operations = UnmodifiableListView(operations);

  bool get hasNext {
    return peekLength() < _maxInt;
  }

  TextOperation? peek() {
    if (_index >= _operations.length) {
      return null;
    }

    return _operations[_index];
  }

  int peekLength() {
    if (_index < _operations.length) {
      final op = _operations[_index];
      return op.length - _offset;
    }
    return _maxInt;
  }

  TextOperation next([int? length]) {
    length ??= _maxInt;

    if (_index >= _operations.length) {
      return TextRetain(_maxInt);
    }

    final nextOp = _operations[_index];

    final offset = _offset;
    final opLength = nextOp.length;
    if (length >= opLength - offset) {
      length = opLength - offset;
      _index += 1;
      _offset = 0;
    } else {
      _offset += length;
    }
    if (nextOp is TextDelete) {
      return TextDelete(length);
    }

    if (nextOp is TextRetain) {
      return TextRetain(
        length,
        nextOp.attributes,
      );
    }

    if (nextOp is TextInsert) {
      return TextInsert(
        nextOp.content.substring(offset, offset + length),
        nextOp.attributes,
      );
    }

    return TextRetain(_maxInt);
  }

  List<TextOperation> rest() {
    if (!hasNext) {
      return [];
    } else if (_offset == 0) {
      return _operations.sublist(_index);
    } else {
      final offset = _offset;
      final index = _index;
      final _next = next();
      final rest = _operations.sublist(_index);
      _offset = offset;
      _index = index;
      return [_next] + rest;
    }
  }
}

TextOperation? _textOperationFromJson(Map<String, dynamic> json) {
  TextOperation? result;

  if (json['insert'] is String) {
    final attrs = json['attributes'] as Map<String, dynamic>?;
    result =
        TextInsert(json['insert'] as String, attrs == null ? null : {...attrs});
  } else if (json['retain'] is int) {
    final attrs = json['attributes'] as Map<String, dynamic>?;
    result =
        TextRetain(json['retain'] as int, attrs == null ? null : {...attrs});
  } else if (json['delete'] is int) {
    result = TextDelete(json['delete'] as int);
  }

  return result;
}

// basically copy from: https://github.com/quilljs/delta
class Delta extends Iterable<TextOperation> {
  final List<TextOperation> _operations;
  String? _rawString;

  factory Delta.fromJson(List<dynamic> list) {
    final operations = <TextOperation>[];

    for (final obj in list) {
      final op = _textOperationFromJson(obj as Map<String, dynamic>);
      if (op != null) {
        operations.add(op);
      }
    }

    return Delta(operations);
  }

  Delta([List<TextOperation>? ops]) : _operations = ops ?? <TextOperation>[];

  void addAll(Iterable<TextOperation> textOps) {
    textOps.forEach(add);
  }

  void add(TextOperation textOp) {
    if (textOp.isEmpty) {
      return;
    }
    _rawString = null;

    if (_operations.isNotEmpty) {
      final lastOp = _operations.last;
      if (lastOp is TextDelete && textOp is TextDelete) {
        lastOp.length += textOp.length;
        return;
      }
      if (mapEquals(lastOp.attributes, textOp.attributes)) {
        if (lastOp is TextInsert && textOp is TextInsert) {
          lastOp.content += textOp.content;
          return;
        }
        // if there is an delete before the insert
        // swap the order
        if (lastOp is TextDelete && textOp is TextInsert) {
          _operations.removeLast();
          _operations.add(textOp);
          _operations.add(lastOp);
          return;
        }
        if (lastOp is TextRetain && textOp is TextRetain) {
          lastOp.length += textOp.length;
          return;
        }
      }
    }

    _operations.add(textOp);
  }

  Delta slice(int start, [int? end]) {
    final result = Delta();
    final iterator = _OpIterator(_operations);
    int index = 0;

    while ((end == null || index < end) && iterator.hasNext) {
      TextOperation? nextOp;
      if (index < start) {
        nextOp = iterator.next(start - index);
      } else {
        nextOp = iterator.next(end == null ? null : end - index);
        result.add(nextOp);
      }

      index += nextOp.length;
    }

    return result;
  }

  void insert(String content, [Attributes? attributes]) =>
      add(TextInsert(content, attributes));

  void retain(int length, [Attributes? attributes]) =>
      add(TextRetain(length, attributes));

  void delete(int length) => add(TextDelete(length));

  int get length {
    return _operations.fold(
        0, (previousValue, element) => previousValue + element.length);
  }

  Delta compose(Delta other) {
    final thisIter = _OpIterator(_operations);
    final otherIter = _OpIterator(other._operations);
    final ops = <TextOperation>[];

    final firstOther = otherIter.peek();
    if (firstOther != null &&
        firstOther is TextRetain &&
        firstOther.attributes == null) {
      int firstLeft = firstOther.length;
      while (
          thisIter.peek() is TextInsert && thisIter.peekLength() <= firstLeft) {
        firstLeft -= thisIter.peekLength();
        final next = thisIter.next();
        ops.add(next);
      }
      if (firstOther.length - firstLeft > 0) {
        otherIter.next(firstOther.length - firstLeft);
      }
    }

    final delta = Delta(ops);
    while (thisIter.hasNext || otherIter.hasNext) {
      if (otherIter.peek() is TextInsert) {
        final next = otherIter.next();
        delta.add(next);
      } else if (thisIter.peek() is TextDelete) {
        final next = thisIter.next();
        delta.add(next);
      } else {
        // otherIs
        final length = min(thisIter.peekLength(), otherIter.peekLength());
        final thisOp = thisIter.next(length);
        final otherOp = otherIter.next(length);
        final attributes =
            composeAttributes(thisOp.attributes, otherOp.attributes);
        if (otherOp is TextRetain && otherOp.length > 0) {
          TextOperation? newOp;
          if (thisOp is TextRetain) {
            newOp = TextRetain(length, attributes);
          } else if (thisOp is TextInsert) {
            newOp = TextInsert(thisOp.content, attributes);
          }

          if (newOp != null) {
            delta.add(newOp);
          }

          // Optimization if rest of other is just retain
          if (!otherIter.hasNext &&
              delta._operations[delta._operations.length - 1] == newOp) {
            final rest = Delta(thisIter.rest());
            return (delta + rest)..chop();
          }
        } else if (otherOp is TextDelete && (thisOp is TextRetain)) {
          delta.add(otherOp);
        }
      }
    }

    return delta..chop();
  }

  Delta operator +(Delta other) {
    var ops = [..._operations];
    if (other._operations.isNotEmpty) {
      ops.add(other._operations[0]);
      ops.addAll(other._operations.sublist(1));
    }
    return Delta(ops);
  }

  void chop() {
    if (_operations.isEmpty) {
      return;
    }
    _rawString = null;
    final lastOp = _operations.last;
    if (lastOp is TextRetain && (lastOp.attributes?.length ?? 0) == 0) {
      _operations.removeLast();
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! Delta) {
      return false;
    }
    return listEquals(_operations, other._operations);
  }

  @override
  int get hashCode {
    return hashList(_operations);
  }

  Delta invert(Delta base) {
    final inverted = Delta();
    _operations.fold(0, (int previousValue, op) {
      if (op is TextInsert) {
        inverted.delete(op.length);
      } else if (op is TextRetain && op.attributes == null) {
        inverted.retain(op.length);
        return previousValue + op.length;
      } else if (op is TextDelete || op is TextRetain) {
        final length = op.length;
        final slice = base.slice(previousValue, previousValue + length);
        for (final baseOp in slice._operations) {
          if (op is TextDelete) {
            inverted.add(baseOp);
          } else if (op is TextRetain && op.attributes != null) {
            inverted.retain(baseOp.length,
                invertAttributes(op.attributes, baseOp.attributes));
          }
        }
        return previousValue + length;
      }
      return previousValue;
    });
    return inverted..chop();
  }

  List<dynamic> toJson() {
    return _operations.map((e) => e.toJson()).toList();
  }

  String toRawString() {
    _rawString ??=
        _operations.whereType<TextInsert>().map((op) => op.content).join();
    return _rawString!;
  }

  @override
  Iterator<TextOperation> get iterator => _operations.iterator;
}
