import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:vantra/core/models/peer_profile.dart';
import 'package:vantra/core/peers/peer_provider.dart';

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
        title: const Text('Contacts & Peers', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1),
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
              decoration: InputDecoration(
                hintText: 'Search contacts by name or nickname...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (val) => setState(() => _searchQuery = val.trim().toLowerCase()),
            ),
          ),

          // Filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All Peers'),
                  selected: _selectedFilterIndex == 0,
                  onSelected: (_) => setState(() => _selectedFilterIndex = 0),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Trusted'),
                  selected: _selectedFilterIndex == 1,
                  avatar: const Icon(Icons.verified, size: 16, color: Colors.greenAccent),
                  onSelected: (_) => setState(() => _selectedFilterIndex = 1),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Blocked'),
                  selected: _selectedFilterIndex == 2,
                  avatar: const Icon(Icons.block, size: 16, color: Colors.redAccent),
                  onSelected: (_) => setState(() => _selectedFilterIndex = 2),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

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

                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.contacts_outlined, size: 64, color: Colors.grey.shade600),
                        const SizedBox(height: 16),
                        Text(
                          _searchQuery.isNotEmpty
                              ? 'No matching peers found'
                              : _selectedFilterIndex == 1
                                  ? 'No trusted peers yet'
                                  : _selectedFilterIndex == 2
                                      ? 'No blocked peers'
                                      : 'No contacts yet',
                          style: const TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (context, index) => const Divider(height: 1, indent: 72, color: Colors.white10),
                  itemBuilder: (context, index) {
                    final peer = filtered[index];
                    return _ContactListTile(
                      peer: peer,
                      onTap: () => context.push('/peer/${peer.peerId}'),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(child: Text('Error: $err', style: const TextStyle(color: Colors.redAccent))),
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
                ? Colors.green.shade800
                : peer.isBlocked
                    ? Colors.red.shade900
                    : Colors.deepPurple.shade700,
            child: Text(
              peer.effectiveName.isNotEmpty ? peer.effectiveName[0].toUpperCase() : '?',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white),
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
                  color: Colors.greenAccent,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF121212), width: 2),
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
                fontSize: 16,
                color: peer.isBlocked ? Colors.grey : Colors.white,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (peer.nickname != null && peer.nickname!.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              '(${peer.displayName})',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ],
      ),
      subtitle: Row(
        children: [
          if (peer.isTrusted)
            const Text('Trusted', style: TextStyle(color: Colors.greenAccent, fontSize: 13))
          else if (peer.isBlocked)
            const Text('Blocked', style: TextStyle(color: Colors.redAccent, fontSize: 13))
          else
            const Text('Untrusted Identity', style: TextStyle(color: Colors.amberAccent, fontSize: 13)),
          if (peer.isOnline) ...[
            const SizedBox(width: 8),
            const Text('• Online', style: TextStyle(color: Colors.greenAccent, fontSize: 13)),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
    );
  }
}
