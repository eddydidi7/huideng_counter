enum HistoryPeriod { today, yesterday, week, month, custom, all }

class HistoryRange {
  final DateTime? from, until;
  const HistoryRange(this.from, this.until);
  factory HistoryRange.forPeriod(HistoryPeriod period, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    return switch (period) {
      HistoryPeriod.today => HistoryRange(today, tomorrow),
      HistoryPeriod.yesterday => HistoryRange(
        DateTime(now.year, now.month, now.day - 1),
        today,
      ),
      HistoryPeriod.week => HistoryRange(
        DateTime(now.year, now.month, now.day - now.weekday + 1),
        tomorrow,
      ),
      HistoryPeriod.month => HistoryRange(
        DateTime(now.year, now.month, 1),
        tomorrow,
      ),
      _ => const HistoryRange(null, null),
    };
  }
  factory HistoryRange.custom(DateTime first, DateTime last) => HistoryRange(
    DateTime(first.year, first.month, first.day),
    DateTime(last.year, last.month, last.day + 1),
  );
}
