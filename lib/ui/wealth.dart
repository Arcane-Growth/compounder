import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import 'widgets.dart';

class WealthTab extends StatelessWidget {
  const WealthTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    final entries = store.accounts.map((a) => (a.balance, a.isLiability)).toList();
    final netWorth = Wealth.netWorth(entries);

    return Scaffold(
      appBar: AppBar(
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
          const ScreenIntro(
            eyebrow: 'COMPOUND YOUR NET WORTH',
            title: 'Own every\nnumber.',
            subtitle:
                'Accounts, assets and debts tracked on your own device. Nothing leaves it unless you export it.',
          ),
          const SizedBox(height: 20),
          Card(
            color: scheme.primary,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('TOTAL NET WORTH',
                    style: t.labelMedium
                        ?.copyWith(color: scheme.onPrimary.withValues(alpha: 0.8))),
                const SizedBox(height: 8),
                Text(Wealth.formatAmount(netWorth),
                    style: t.displaySmall?.copyWith(color: scheme.onPrimary)),
                const SizedBox(height: 8),
                Text('${store.accounts.length} accounts tracked locally',
                    style: t.bodySmall
                        ?.copyWith(color: scheme.onPrimary.withValues(alpha: 0.8))),
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
                      value: Wealth.formatAmount(Wealth.totalLiabilities(entries)))),
            ]),
          ],
          const SizedBox(height: 20),
          const SectionHeader('Accounts'),
          const SizedBox(height: 8),
          if (store.accounts.isEmpty)
            const EmptyState(
              title: 'No accounts yet',
              subtitle: 'Add your bank, brokerage or cash accounts to see your net worth at a glance.',
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
                  trailing: '${account.currency} ${Wealth.formatAmount(account.balance)}',
                  onTap: () => _showAccountDialog(context, store, account),
                )),
        ],
      ),
    );
  }

  void _showAccountDialog(BuildContext context, AppStore store, Account? existing) {
    final name = TextEditingController(text: existing?.name ?? '');
    final balance = TextEditingController(text: existing?.balance.toString() ?? '');
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
                        onSelected: (_) => setDialogState(() => type = typeOption),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                    controller: balance,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Balance')),
                const SizedBox(height: 12),
                TextField(controller: currency, decoration: const InputDecoration(labelText: 'Currency')),
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
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                store.saveAccount(Account(
                  id: existing?.id ?? 0,
                  name: name.text.trim().isEmpty ? type : name.text.trim(),
                  type: type,
                  balance: double.tryParse(balance.text) ?? 0,
                  currency: currency.text.trim().isEmpty ? 'USD' : currency.text.trim().toUpperCase(),
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
