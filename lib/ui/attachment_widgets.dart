import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/store.dart';
import '../sync/sync_service.dart';
import 'format.dart';

/// Opens an attachment: images in an in-app viewer, everything else (PDF,
/// Office files, audio...) in whatever app the OS associates with it.
/// Downloads it from the sync repository first if this device lacks it.
Future<void> openAttachment(BuildContext context, AttachmentRef ref) async {
  final store = context.read<NoteStore>();
  final sync = context.read<SyncService>();
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  try {
    File file;
    if (store.hasBlob(ref.hash)) {
      file = store.blobFile(ref.hash);
    } else {
      messenger.showSnackBar(SnackBar(content: Text('Downloading ${ref.name}…')));
      file = await sync.ensureAttachment(ref);
      messenger.hideCurrentSnackBar();
    }
    if (ref.isImage) {
      await nav.push(MaterialPageRoute<void>(
        builder: (_) => ImageViewerPage(file: file, title: ref.name),
      ));
      return;
    }
    final out = await store.exportForOpen(ref);
    final res = await OpenFilex.open(out.path);
    if (res.type != ResultType.done) {
      messenger.showSnackBar(
          SnackBar(content: Text('No app found to open ${ref.name}.')));
    }
  } catch (e) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({
    super.key,
    required this.attachments,
    required this.onRemove,
  });

  final List<AttachmentRef> attachments;
  final void Function(AttachmentRef) onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 124,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: attachments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) => AttachmentTile(
          ref: attachments[i],
          onRemove: () => onRemove(attachments[i]),
        ),
      ),
    );
  }
}

class AttachmentTile extends StatelessWidget {
  const AttachmentTile({super.key, required this.ref, required this.onRemove});

  final AttachmentRef ref;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final store = context.watch<NoteStore>();
    final local = store.hasBlob(ref.hash);

    Widget preview;
    if (ref.isImage && local) {
      preview = Image.file(
        store.blobFile(ref.hash),
        fit: BoxFit.cover,
        cacheWidth: 320,
        errorBuilder: (_, __, ___) => _iconBox(cs, Icons.broken_image_outlined),
      );
    } else {
      preview = _iconBox(
        cs,
        local ? iconForMime(ref.mime, ref.name) : Icons.cloud_download_outlined,
      );
    }

    return SizedBox(
      width: 120,
      child: Stack(
        children: [
          Material(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => openAttachment(context, ref),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: preview),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ref.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium),
                        Text(fmtBytes(ref.size),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: cs.surface.withValues(alpha: 0.85),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconBox(ColorScheme cs, IconData icon) => Container(
        color: cs.secondaryContainer.withValues(alpha: 0.6),
        alignment: Alignment.center,
        child: Icon(icon, size: 32, color: cs.onSecondaryContainer),
      );
}

class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({super.key, required this.file, required this.title});

  final File file;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, overflow: TextOverflow.ellipsis),
      ),
      body: InteractiveViewer(
        minScale: 0.5,
        maxScale: 6,
        child: Center(child: Image.file(file)),
      ),
    );
  }
}
