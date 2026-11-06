import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import 'drawer.dart';
import 'widgets.dart';

class WealthTab extends StatelessWidget {
  const WealthTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    final entries =
        store.accounts.map((a) => (a.balance, a.isLiability)).toList();
    final netWorth = Wealth.netWorth(entries);

    return Scaffold(
      appBar: AppBar(
        leading: const DrawerMenuButton(),
        title: Row(children: [
          TintedIconCircle(Icons.insights,
              background: scheme.primary, foreground: scheme.onPrimary),
          const SizedBox(width: 10),
          Text('Wealth', style: t.titleLarge),
        ]),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'add-account',
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        onPressed: () => _showAccountDialog(context, store, null),
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 96),
        children: [
          _NetWorthTrendCard(points: store.netWorthHistory),
          const SizedBox(height: 20),
          Card(
            color: scheme.primary,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TOTAL NET WORTH',
                        style: t.labelMedium?.copyWith(
                            color: scheme.onPrimary.withValues(alpha: 0.8))),
                    const SizedBox(height: 8),
                    Text(Wealth.formatAmount(netWorth),
                        style:
                            t.displaySmall?.copyWith(color: scheme.onPrimary)),
                    const SizedBox(height: 8),
                    Text('${store.accounts.length} accounts tracked locally',
                        style: t.bodySmall?.copyWith(
                            color: scheme.onPrimary.withValues(alpha: 0.8))),
                  ]),
            ),
          ),
          if (store.accounts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: StatCard(
                      label: 'Assets',
                      value: Wealth.formatAmount(Wealth.totalAssets(entries)))),
              const SizedBox(width: 8),
              Expanded(
                  child: StatCard(
                      label: 'Liabilities',
                      value: Wealth.formatAmount(
                          Wealth.totalLiabilities(entries)))),
            ]),
          ],
          const SizedBox(height: 20),
          const SectionHeader('Accounts'),
          const SizedBox(height: 8),
          if (store.accounts.isEmpty)
            const EmptyState(
              title: 'No accounts yet',
              subtitle:
                  'Add your bank, brokerage or cash accounts to see your net worth at a glance.',
              icon: Icons.insights,
            )
          else
            ...store.accounts.map((account) => CardRow(
                  icon: switch (account.type) {
                    'Cash' => Icons.payments,
                    'Bank' => Icons.account_balance,
                    'Brokerage' => Icons.candlestick_chart,
                    'Retirement' => Icons.workspace_premium,
                    'Crypto' => Icons.currency_bitcoin,
                    'Property' => Icons.home,
                    'Debt' => Icons.credit_card,
                    _ => Icons.more_horiz,
                  },
                  title: account.name,
                  subtitle:
                      '${account.type} · updated ${formatDate(account.updatedAt)}',
                  trailing:
                      '${account.currency} ${Wealth.formatAmount(account.balance)}',
                  trailingAction: IconButton(
                    icon: const Icon(Icons.edit_note, size: 20),
                    tooltip: 'Update value',
                    visualDensity: VisualDensity.compact,
                    color: scheme.primary,
                    onPressed: () =>
                        _showBalanceDialog(context, store, account),
                  ),
                  onTap: () => _showAccountDialog(context, store, account),
                )),
        ],
      ),
    );
  }

  void _showBalanceDialog(
      BuildContext context, AppStore store, Account account) {
    final balance = TextEditingController(text: account.balance.toString());
    String? error;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Update ${account.name}'),
          content: TextField(
            controller: balance,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true, signed: true),
            decoration: InputDecoration(
              labelText: 'Balance (${account.currency})',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final value = double.tryParse(balance.text.trim());
                if (value == null) {
                  setDialogState(() => error = 'Enter a number');
                  return;
                }
                store.saveAccount(Account(
                  id: account.id,
                  name: account.name,
                  type: account.type,
                  balance: value,
                  currency: account.currency,
                  updatedAt: account.updatedAt,
                ));
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showAccountDialog(
      BuildContext context, AppStore store, Account? existing) {
    final name = TextEditingController(text: existing?.name ?? '');
    final balance =
        TextEditingController(text: existing?.balance.toString() ?? '');
    final currency = TextEditingController(text: existing?.currency ?? 'USD');
    var type = existing?.type ?? 'Bank';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add account' : 'Edit account'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                    controller: name,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final typeOption in Account.types)
                      ChoiceChip(
                        label: Text(typeOption),
                        selected: type == typeOption,
                        onSelected: (_) =>
                            setDialogState(() => type = typeOption),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                    controller: balance,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Balance')),
                const SizedBox(height: 12),
                TextField(
                    controller: currency,
                    decoration: const InputDecoration(labelText: 'Currency')),
              ],
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () {
                  store.deleteAccount(existing.id);
                  Navigator.pop(context);
                },
                child: Text('Delete',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                store.saveAccount(Account(
                  id: existing?.id ?? 0,
                  name: name.text.trim().isEmpty ? type : name.text.trim(),
                  type: type,
                  balance: double.tryParse(balance.text) ?? 0,
                  currency: currency.text.trim().isEmpty
                      ? 'USD'
                      : currency.text.trim().toUpperCase(),
                  updatedAt: existing?.updatedAt ?? 0,
                ));
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NetWorthTrendCard extends StatelessWidget {
  final List<NetWorthPoint> points;
  const _NetWorthTrendCard({required this.points});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final hasTrend = points.length >= 2;

    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('NET WORTH TREND',
              style: t.labelMedium?.copyWith(color: scheme.primary)),
          const SizedBox(height: 4),
          Text(
            hasTrend
                ? 'Recorded whenever you update an account.'
                : 'Update an account to start building your net worth history.',
            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (hasTrend) ...[
            const SizedBox(height: 16),
            SizedBox(height: 200, child: _chart(scheme)),
          ],
        ]),
      ),
    );
  }

  Widget _chart(ColorScheme scheme) {
    final values = points.map((p) => p.value).toList();
    final lo = values.reduce(math.min);
    final hi = values.reduce(math.max);
    final pad = math.max(
      (hi - lo) * 0.08,
      math.max(1.0, math.max(hi.abs(), lo.abs()) * 0.02),
    );

    return LineChart(
      LineChartData(
        minY: lo - pad,
        maxY: hi + pad,
        titlesData: FlTitlesData(
          rightTitles: const AxisTitles(),
          topTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (value, meta) => Text(
                _compactAmount(value),
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: (points.length / 4).ceilToDouble().clamp(1, 99),
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= points.length) return const SizedBox();
                final date =
                    DateTime.fromMillisecondsSinceEpoch(points[idx].date);
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${date.month}/${date.day}',
                    style: const TextStyle(fontSize: 10),
                  ),
                );
              },
            ),
          ),
        ),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            isCurved: true,
            curveSmoothness: 0.25,
            color: scheme.primary,
            barWidth: 3,
            dotData: FlDotData(show: points.length <= 30),
            spots: [
              for (var i = 0; i < points.length; i++)
                FlSpot(i.toDouble(), points[i].value)
            ],
          ),
        ],
      ),
    );
  }

  String _compactAmount(double value) {
    final abs = value.abs();
    final sign = value < 0 ? '-' : '';
    if (abs >= 1000000) return '$sign${(abs / 1000000).toStringAsFixed(1)}M';
    if (abs >= 1000) return '$sign${(abs / 1000).toStringAsFixed(0)}k';
    return '$sign${abs.toStringAsFixed(0)}';
  }
}
