import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';

class MemberAvatar extends StatelessWidget {
  const MemberAvatar({super.key, required this.member, this.radius = 16});

  final Member member;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = member.avatarUrl;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.secondaryContainer,
      foregroundImage: url != null ? CachedNetworkImageProvider(url) : null,
      child: Text(
        member.initials,
        style: TextStyle(
          fontSize: radius * 0.75,
          fontWeight: FontWeight.w600,
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// Overlapping avatars, e.g. for the people sharing a list.
class AvatarStack extends StatelessWidget {
  const AvatarStack({super.key, required this.members, this.radius = 13, this.max = 4});

  final List<Member> members;
  final double radius;
  final int max;

  @override
  Widget build(BuildContext context) {
    final shown = members.take(max).toList();
    final extra = members.length - shown.length;
    final surface = Theme.of(context).colorScheme.surface;
    final step = radius * 1.4;
    final count = shown.length + (extra > 0 ? 1 : 0);
    return SizedBox(
      height: radius * 2 + 4,
      width: count == 0 ? 0 : step * (count - 1) + radius * 2 + 4,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * step,
              child: CircleAvatar(
                radius: radius + 2,
                backgroundColor: surface,
                child: MemberAvatar(member: shown[i], radius: radius),
              ),
            ),
          if (extra > 0)
            Positioned(
              left: shown.length * step,
              child: CircleAvatar(
                radius: radius + 2,
                backgroundColor: surface,
                child: CircleAvatar(radius: radius, child: Text('+$extra', style: TextStyle(fontSize: radius * 0.7))),
              ),
            ),
        ],
      ),
    );
  }
}
