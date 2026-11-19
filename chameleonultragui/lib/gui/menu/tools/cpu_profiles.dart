import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/create.dart';
import 'package:chameleonultragui/gui/menu/dialogs/card/edit.dart';
import 'package:chameleonultragui/gui/menu/dialogs/confirm_delete.dart';
import 'package:chameleonultragui/gui/menu/pages/cpu_data_editor.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class CpuProfilesPage extends StatelessWidget {
  const CpuProfilesPage({super.key});

  void _saveData(ChameleonGUIState app, CardSave updated) {
    final prefs = app.sharedPreferencesProvider;
    final cards = prefs.getCards();
    final index = cards.indexWhere((card) => card.id == updated.id);
    if (index == -1) return;
    // The data editor does not own the identity or card-library metadata.
    cards[index].data = updated.data;
    cards[index].extraData.cpuDump = updated.extraData.cpuDump;
    prefs.setCards(cards);
    app.changesMade();
  }

  Future<void> _delete(
    BuildContext context,
    ChameleonGUIState app,
    CardSave card,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDeletionMenu(thingBeingDeleted: card.name),
    );
    if (confirmed != true || !context.mounted) return;
    final prefs = app.sharedPreferencesProvider;
    prefs.setCards(
      prefs.getCards()..removeWhere((entry) => entry.id == card.id),
    );
    app.changesMade();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<ChameleonGUIState>();
    final l = AppLocalizations.of(context)!;
    final cards = app.sharedPreferencesProvider
        .getCards()
        .where((card) => card.tag == TagType.hf14a4)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(l.cpu_manage_profile_library),
        actions: [
          IconButton(
            tooltip: l.create_card,
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const CardCreateMenu(initialType: TagType.hf14a4),
            ),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: cards.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l.cpu_manage_no_profiles),
              ),
            )
          : ListView.builder(
              itemCount: cards.length,
              itemBuilder: (context, index) {
                final card = cards[index];
                return ListTile(
                  leading: Icon(Icons.credit_card, color: card.color),
                  title: Text(card.name),
                  subtitle: Text('UID ${card.uid}'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CpuDataEditor(
                        card: card,
                        onSave: (updated) => _saveData(app, updated),
                      ),
                    ),
                  ),
                  trailing: PopupMenuButton<bool>(
                    onSelected: (delete) {
                      if (delete) {
                        _delete(context, app, card);
                      } else {
                        showDialog<void>(
                          context: context,
                          builder: (_) => CardEditMenu(tagSave: card),
                        );
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: false, child: Text(l.edit_card)),
                      PopupMenuItem(value: true, child: Text(l.delete)),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
