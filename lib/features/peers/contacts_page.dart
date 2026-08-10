import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/models/peer_profile.dart';
import 'package:vantra/core/peers/peer_provider.dart';
import 'package:vantra/core/themes/vantra_theme.dart';

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  String _searchQuery = '';
  int _selectedFilterIndex = 0; // 0 = All, 1 = Trusted, 2 = Blocked

  @override
  Widget build(BuildContext context) {
    final allPeersAsync = ref.watch(allPeersStreamProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1_rounded),
            tooltip: 'Discover Nearby',
            onPressed: () => context.push('/nearby'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              style: const TextStyle(color: VantraTheme.textPrimary),
              decoration: InputDecoration(
                hintText: 'Search contacts by name or nickname...',
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
              onChanged: (val) => setState(() => _searchQuery = val.trim().toLowerCase()),
            ),
          ),

          // Filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All Contacts'),
                  selected: _selectedFilterIndex == 0,
                  onSelected: (_) => setState(() => _selectedFilterIndex = 0),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Trusted'),
                  selected: _selectedFilterIndex == 1,
                  avatar: const Icon(Icons.verified_rounded, size: 16, color: VantraTheme.greenVerified),
                  onSelected: (_) => setState(() => _selectedFilterIndex == 1),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Blocked'),
                  selected: _selectedFilterIndex == 2,
                  avatar: const Icon(Icons.block_flipped, size: 16, color: VantraTheme.redBlocked),
                  onSelected: (_) => setState(() => _selectedFilterIndex == 2),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),

          // Peer list
          Expanded(
            child: allPeersAsync.when(
              data: (peers) {
                var filtered = peers.where((p) {
                  // Search query filter
                  if (_searchQuery.isNotEmpty) {
                    final nameMatch = p.displayName.toLowerCase().contains(_searchQuery);
                    final nickMatch = p.nickname?.toLowerCase().contains(_searchQuery) ?? false;
                    if (!nameMatch && !nickMatch) return false;
                  }

                  // Category filter
                  if (_selectedFilterIndex == 1) return p.isTrusted;
                  if (_selectedFilterIndex == 2) return p.isBlocked;
                  return true;
                }).toList();

                // Sort alphabetically by effective name
                filtered.sort((a, b) => a.effectiveName.toLowerCase().compareTo(b.effectiveName.toLowerCase()));

                if (filtered.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.contacts_outlined,
                                size: 56,
                                color: VantraTheme.primary.withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 24),
                              Text(
                                _searchQuery.isNotEmpty
                                    ? 'No matching peers found'
                                    : _selectedFilterIndex == 1
                                        ? 'No trusted peers yet'
                                        : _selectedFilterIndex == 2
                                            ? 'No blocked peers'
                                            : 'No contacts yet',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: VantraTheme.textPrimary),
                              ),
                              if (_searchQuery.isEmpty && _selectedFilterIndex == 0) ...[
                                const SizedBox(height: 12),
                                const Text(
                                  'Find nearby devices and connect to add them to your offline contacts list.',
                                  style: TextStyle(fontSize: 13, color: VantraTheme.textSecondary, height: 1.4),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 24),
                                ElevatedButton.icon(
                                  onPressed: () => context.push('/nearby'),
                                  icon: const Icon(Icons.radar_rounded),
                                  label: const Text('Discover Nearby'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }

                // Render contact items with alphabetical headers
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final peer = filtered[index];
                    final currentLetter = peer.effectiveName.isNotEmpty
                        ? peer.effectiveName[0].toUpperCase()
                        : '?';
                    final showHeader = index == 0 ||
                        (filtered[index - 1].effectiveName.isNotEmpty &&
                            filtered[index - 1].effectiveName[0].toUpperCase() != currentLetter);

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showHeader)
                          Padding(
                            padding: const EdgeInsets.only(left: 16, top: 16, bottom: 8),
                            child: Text(
                              currentLetter,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: VantraTheme.primaryAccent,
                              ),
                            ),
                          ),
                        _ContactListTile(
                          peer: peer,
                          onTap: () => context.push('/peer/${peer.peerId}'),
                        ),
                      ],
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator(color: VantraTheme.primary)),
              error: (err, _) => Center(child: Text('Error: $err', style: const TextStyle(color: VantraTheme.redBlocked))),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactListTile extends StatelessWidget {
  final PeerProfile peer;
  final VoidCallback onTap;

  const _ContactListTile({
    required this.peer,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: peer.isTrusted
                ? VantraTheme.greenVerified.withValues(alpha: 0.15)
                : peer.isBlocked
                    ? VantraTheme.redBlocked.withValues(alpha: 0.15)
                    : VantraTheme.primary.withValues(alpha: 0.15),
            child: Text(
              peer.effectiveName.isNotEmpty ? peer.effectiveName[0].toUpperCase() : '?',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: peer.isTrusted
                    ? VantraTheme.greenVerified
                    : peer.isBlocked
                        ? VantraTheme.redBlocked
                        : VantraTheme.primaryAccent,
              ),
            ),
          ),
          if (peer.isOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: VantraTheme.greenVerified,
                  shape: BoxShape.circle,
                  border: Border.all(color: VantraTheme.background, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              peer.effectiveName,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15.5,
                color: peer.isBlocked ? VantraTheme.textMuted : VantraTheme.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (peer.nickname != null && peer.nickname!.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              '(${peer.displayName})',
              style: const TextStyle(fontSize: 12.5, color: VantraTheme.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
      subtitle: Row(
        children: [
          if (peer.isTrusted)
            const Text('Trusted Identity', style: TextStyle(color: VantraTheme.greenVerified, fontSize: 13))
          else if (peer.isBlocked)
            const Text('Blocked', style: TextStyle(color: VantraTheme.redBlocked, fontSize: 13))
          else
            const Text('Untrusted Identity', style: TextStyle(color: VantraTheme.amberWarning, fontSize: 13)),
          if (peer.isOnline) ...[
            const SizedBox(width: 8),
            const Text('• Online', style: TextStyle(color: VantraTheme.greenVerified, fontSize: 13)),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right_rounded, color: VantraTheme.textMuted),
    );
  }
}
