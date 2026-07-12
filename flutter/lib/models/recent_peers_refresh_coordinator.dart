import 'peer_model.dart';
import 'server_profile_model.dart';

void markRecentPeersFreshFromReceipt({
  required RecentPeersModel recentPeers,
  required ServerProfileModelBase serverProfiles,
  required RecentPeersRefreshReceipt receipt,
}) {
  if (!recentPeers.isCurrentReceipt(receipt) ||
      serverProfiles.activeProfileId != receipt.profileId ||
      serverProfiles.busy) {
    return;
  }
  serverProfiles.markRecentPeersFresh(receipt.profileId);
}
