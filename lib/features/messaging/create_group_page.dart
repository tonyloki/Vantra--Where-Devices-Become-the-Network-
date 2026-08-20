import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/messaging/messaging_provider.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/themes/vantra_theme.dart';

class CreateGroupPage extends ConsumerStatefulWidget {
  const CreateGroupPage({super.key});

  @override
  ConsumerState<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends ConsumerState<CreateGroupPage> {
  final _nameController = TextEditingController();
  final Set<String> _selectedPeerIds = {};
  String _searchQuery = '';

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _toggleSelection(String peerId) {
    setState(() {
      if (_selectedPeerIds.contains(peerId)) {
        _selectedPeerIds.remove(peerId);
      } else {
        _selectedPeerIds.add(peerId);
      }
    });
  }

  Future<void> _createGroup() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _selectedPeerIds.isEmpty) return;

    // Show loading overlay
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: CircularProgressIndicator(color: VantraTheme.primary),
      ),
    );

    try {
      await ref.read(messagingStateProvider.notifier).createAndInviteGroup(
        name,
        _selectedPeerIds.toList(),
      );
      if (mounted) {
        // Pop loading dialog
        Navigator.pop(context);
        // Navigate back
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create group: $e'),
            backgroundColor: VantraTheme.redBlocked,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final trustedPeersAsync = ref.watch(trustedPeersStreamProvider);

    final canCreate = _nameController.text.trim().isNotEmpty && _selectedPeerIds.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Create New Group'),
        actions: [
          TextButton(
            onPressed: canCreate ? _createGroup : null,
            child: Text(
              'CREATE',
              style: TextStyle(
                color: canCreate ? VantraTheme.primaryAccent : Colors.grey,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Group Name Input
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _nameController,
              style: const TextStyle(color: VantraTheme.textPrimary, fontSize: 18),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Enter group name...',
                hintStyle: const TextStyle(color: VantraTheme.textMuted),
                prefixIcon: const Icon(Icons.group_add_rounded, color: VantraTheme.primaryAccent),
                filled: true,
                fillColor: VantraTheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Search Contacts Input
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              style: const TextStyle(color: VantraTheme.textPrimary),
              onChanged: (val) => setState(() => _searchQuery = val.trim().toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Search trusted contacts...',
                hintStyle: const TextStyle(color: VantraTheme.textMuted),
                prefixIcon: const Icon(Icons.search_rounded, color: VantraTheme.textMuted),
                filled: true,
                fillColor: VantraTheme.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'SELECT MEMBERS',
                style: TextStyle(
                  color: VantraTheme.textMuted,
                  fontSize: 12,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

          // Contacts List
          Expanded(
            child: trustedPeersAsync.when(
              data: (peers) {
                final filtered = peers.where((p) {
                  final nameMatch = p.displayName.toLowerCase().contains(_searchQuery);
                  final nickMatch = p.nickname?.toLowerCase().contains(_searchQuery) ?? false;
                  return nameMatch || nickMatch;
                }).toList();

                if (filtered.isEmpty) {
                  return const Center(
                    child: Text(
                      'No trusted contacts found',
                      style: TextStyle(color: VantraTheme.textMuted),
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final peer = filtered[index];
                    final isSelected = _selectedPeerIds.contains(peer.peerId);

                    return ListTile(
                      onTap: () => _toggleSelection(peer.peerId),
                      leading: CircleAvatar(
                        backgroundColor: isSelected
                            ? VantraTheme.primary.withValues(alpha: 0.3)
                            : VantraTheme.surface,
                        child: Text(
                          peer.displayName.isNotEmpty
                              ? peer.displayName[0].toUpperCase()
                              : '?',
                          style: TextStyle(
                            color: isSelected ? VantraTheme.primaryAccent : Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(
                        peer.displayName,
                        style: const TextStyle(color: VantraTheme.textPrimary),
                      ),
                      subtitle: peer.nickname != null
                          ? Text(
                              '@${peer.nickname}',
                              style: const TextStyle(color: VantraTheme.textMuted),
                            )
                          : null,
                      trailing: Checkbox(
                        value: isSelected,
                        onChanged: (_) => _toggleSelection(peer.peerId),
                        activeColor: VantraTheme.primaryAccent,
                        checkColor: Colors.black,
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(
                child: CircularProgressIndicator(color: VantraTheme.primary),
              ),
              error: (err, _) => Center(
                child: Text('Error loading contacts: $err',
                    style: const TextStyle(color: VantraTheme.redBlocked)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
