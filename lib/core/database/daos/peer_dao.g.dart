// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'peer_dao.dart';

// ignore_for_file: type=lint
mixin _$PeerDaoMixin on DatabaseAccessor<AppDatabase> {
  $PeersTable get peers => attachedDatabase.peers;
  PeerDaoManager get managers => PeerDaoManager(this);
}

class PeerDaoManager {
  final _$PeerDaoMixin _db;
  PeerDaoManager(this._db);
  $$PeersTableTableManager get peers =>
      $$PeersTableTableManager(_db.attachedDatabase, _db.peers);
}
