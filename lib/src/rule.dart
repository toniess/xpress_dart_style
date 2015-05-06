// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.rule;

import 'chunk.dart';

// TODO(bob): Doc.
/// A constraint that determines the different ways a related set of chunks may
/// be split.
abstract class Rule {
  static int _nextId = 0;

  /// A semi-unique numeric indentifier for the rule.
  ///
  /// This is useful for debugging and also speeds up using the rule in hash
  /// sets. Ids are *semi*-unique because they may wrap around in long running
  /// processes. Since rules are equal based on their identity, this is
  /// innocuous and prevents ids from growing without bound.
  final int id = _nextId = (_nextId + 1) & 0x0fffffff;

  /// The number of different states this rule can be in.
  ///
  /// Each state determines which set of chunks using this rule are split and
  /// which aren't. Values range from zero to one minus this. Value zero
  /// always means "no chunks are split" and increasing values by convention
  /// mean increasingly undesirable splits.
  int get numValues;

  /// The rule value that forces this rule into its maximally split state.
  ///
  /// By convention, this is the highest of the range of allowed values.
  int get fullySplitValue => numValues - 1;

  int get cost => Cost.normal;

  /// The span of [Chunk]s that were written while this rule was still in
  /// effect.
  ///
  /// This is used to tell which rules should be pre-emptively split if their
  /// contents are too long. This may be a wider range than the set of chunks
  /// enclosed by chunks whose rule is this one. A rule may still be on the
  /// list of open rules for a while after its last chunk is written.
  // TODO(bob): This is only being used by preemption which is kind of hacky.
  // Get rid of this?
  Span get span => _span;
  Span _span;

  /// The other [Rule]s that are "implied" by this one.
  ///
  /// Implication means that if the splitter chooses to split this rule (i.e.
  /// set its value to something non-zero), it must also force all of its
  /// implied rules to have some non-zero value (transitively). Implication is
  /// one-way. If A implies B, it's fine to split B without splitting A.
  ///
  /// This contains all direct as well as transitive implications. If A implies
  /// B which implies C, A's implies set includes both B and C.
  final Set<Rule> implies = new Set<Rule>();

  /// Whether this rule cares about rules that it contains.
  ///
  /// If `true` then inner rules will imply this one and force it to split when
  /// they split. Otherwise, it can split independently of any contained rules.
  // TODO(bob): Ugh. Better name.
  bool get canBeImplied => true;

  int get hashCode => id.hashCode;

  /// Creates the [Span] associated with this rule's bounds, starting at
  /// [startChunk].
  void startSpan(int startChunk) {
    assert(_span == null);
    _span = new Span(startChunk, 0);
  }

  bool isSplit(int value, Chunk chunk);

  String toString() => "$id";
}

/// A rule that always splits a chunk.
class HardSplitRule extends Rule {
  int get numValues => 1;

  /// It's always split anyway.
  bool get canBeImplied => false;

  bool isSplit(int value, Chunk chunk) => true;

  String toString() => "Hard";
}

/// A basic rule that has two states: unsplit or split.
class SimpleRule extends Rule {
  /// Two values: 0 is unsplit, 1 is split.
  int get numValues => 2;

  final int cost;

  final bool canBeImplied;

  SimpleRule({int cost, bool canBeImplied})
      : cost = cost != null ? cost : Cost.normal,
        canBeImplied = canBeImplied != null ? canBeImplied : true;

  bool isSplit(int value, Chunk chunk) => value == 1;

  String toString() => "Simple${super.toString()}";
}

/// Handles a list of [combinators] following an "import" or "export" directive.
/// Combinators can be split in a few different ways:
///
///     // All on one line:
///     import 'animals.dart' show Ant hide Cat;
///
///     // Wrap before each keyword:
///     import 'animals.dart'
///         show Ant, Baboon
///         hide Cat;
///
///     // Wrap either or both of the name lists:
///     import 'animals.dart'
///         show
///             Ant,
///             Baboon
///         hide Cat;
///
/// These are not allowed:
///
///     // Wrap list but not keyword:
///     import 'animals.dart' show
///             Ant,
///             Baboon
///         hide Cat;
///
///     // Wrap one keyword but not both:
///     import 'animals.dart'
///         show Ant, Baboon hide Cat;
///
/// This ensures that when any wrapping occurs, the keywords are always at
/// the beginning of the line.
class CombinatorRule extends Rule {
  /// The set of chunks before the combinators.
  final Set<Chunk> _combinators = new Set();

  /// A list of sets of chunks prior to each name in a combinator.
  ///
  /// The outer list is a list of combinators (i.e. "hide", "show", etc.). Each
  /// inner set is the set of names for that combinator.
  final List<Set<Chunk>> _names = [];

  int get numValues {
    var count = 2; // No wrapping, or wrap just before each combinator.

    if (_names.length == 2) {
      count += 3; // Wrap first set of names, second, or both.
    } else {
      assert(_names.length == 1);
      count++; // Wrap the names.
    }

    return count;
  }

  /// Adds a new combinator to the list of combinators.
  ///
  /// This must be called before adding any names.
  void addCombinator(Chunk chunk) {
    _combinators.add(chunk);
    _names.add(new Set());
  }

  /// Adds a chunk prior to a name to the current combinator.
  void addName(Chunk chunk) {
    _names.last.add(chunk);
  }

  bool isSplit(int value, Chunk chunk) {
    switch (value) {
      case 0:
        // Don't split at all.
        return false;

      case 1:
        // Just split at the combinators.
        return _combinators.contains(chunk);

      case 2:
        // Split at the combinators and the first set of names.
        return _isCombinatorSplit(0, chunk);

      case 3:
        // If there is two combinators, just split at the combinators and the
        // second set of names.
        if (_names.length == 2) {
          // Two sets of combinators, so just split at the combinators and the
          // second set of names.
          return _isCombinatorSplit(1, chunk);
        }

        // Split everything.
        return true;

      case 4:
        return true;
    }

    throw "unreachable";
  }

  /// Returns `true` if [chunk] is for a combinator or a name in the
  /// combinator at index [combinator].
  bool _isCombinatorSplit(int combinator, Chunk chunk) {
    return _combinators.contains(chunk) || _names[combinator].contains(chunk);
  }

  String toString() => "Comb${super.toString()}";
}

/// Splitting rule for a list of position arguments or parameters. Given an
/// argument list with, say, 5 arguments, its values mean:
///
/// * 0: Do not split at all.
/// * 1: Split only before first argument.
/// * 2...5: Split between one pair of arguments working back to front.
/// * 6: Split before all arguments, including the first.
class PositionalArgsRule extends Rule {
  /// The chunks prior to each positional argument.
  final List<Chunk> _arguments = [];

  int get numValues {
    // If there is just one argument, can either split before it or not.
    if (_arguments.length == 1) return 2;

    // With multiple arguments, can split before any one, none, or all.
    return 2 + _arguments.length;
  }

  void beforeArgument(Chunk chunk) {
    _arguments.add(chunk);
  }

  bool isSplit(int value, Chunk chunk) {
    // Don't split at all.
    if (value == 0) return false;

    // If there is only one argument, split before it.
    if (_arguments.length == 1) return true;

    // Split only before the first argument. Keep the entire argument list
    // together on the next line.
    if (value == 1) return chunk == _arguments.first;

    // Put each argument on its own line.
    if (value == numValues - 1) return true;

    // Otherwise, split between exactly one pair of arguments. Try later
    // arguments before earlier ones to try to keep as much on the first line
    // as possible.
    var argument = numValues - value - 1;
    return chunk == _arguments[argument];
  }

  String toString() => "Pos${super.toString()}";
}

/// Splitting rule for a list of named arguments or parameters. Its values mean:
///
/// * 0: Do not split at all.
/// * 1: Split only before first argument.
/// * 2: Split before all arguments, including the first.
class NamedArgsRule extends Rule {
  /// The chunk prior to the first named argument.
  Chunk _first;

  int get numValues => 3;

  void beforeArguments(Chunk chunk) {
    assert(_first == null);
    _first = chunk;
  }

  bool isSplit(int value, Chunk chunk) {
    switch (value) {
      case 0: return false;
      case 1: return chunk == _first;
      case 2: return true;
    }

    throw "unreachable";
  }

  String toString() => "Named${super.toString()}";
}
