// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:meta/meta.dart';

import '../../common.dart' as common;
import '../../interface.dart';
import '../../io.dart' as io;
import 'common.dart';
import 'memory_file.dart';
import 'memory_file_system_entity.dart';
import 'memory_link.dart';
import 'node.dart';
import 'operations.dart';
import 'style.dart';
import 'utils.dart' as utils;

// Tracks a unique name for system temp directories, per filesystem
// instance.
final Expando<int> _systemTempCounter = Expando<int>();

/// Internal implementation of [Directory].
class MemoryDirectory extends MemoryFileSystemEntity
    with common.DirectoryAddOnsMixin
    implements Directory {
  /// Instantiates a new [MemoryDirectory].
  MemoryDirectory(super.fileSystem, super.path);

  @override
  io.FileSystemEntityType get expectedType => io.FileSystemEntityType.directory;

  @override
  Uri get uri {
    return Uri.directory(path,
        windows: fileSystem.style == FileSystemStyle.windows);
  }

  @override
  bool existsSync() {
    fileSystem.opHandle.call(path, FileSystemOp.exists);
    return backingOrNull?.stat.type == expectedType;
  }

  @override
  Future<Directory> create({bool recursive = false}) async {
    createSync(recursive: recursive);
    return this;
  }

  @override
  void createSync({bool recursive = false}) {
    fileSystem.opHandle(path, FileSystemOp.create);
    var node = internalCreateSync(
      followTailLink: true,
      visitLinks: true,
      createChild: (DirectoryNode parent, bool isFinalSegment) {
        if (recursive || isFinalSegment) {
          return DirectoryNode(parent);
        }
        return null;
      },
    );
    if (node?.type != expectedType) {
      // There was an existing non-directory node at this object's path
      throw common.notADirectory(path);
    }
  }

  @override
  Future<Directory> createTemp([String? prefix]) async =>
      createTempSync(prefix);

  @override
  Directory createTempSync([String? prefix]) {
    prefix = '${prefix ?? ''}rand';
    var fullPath = fileSystem.path.join(path, prefix);
    var dirname = fileSystem.path.dirname(fullPath);
    var basename = fileSystem.path.basename(fullPath);
    var node = fileSystem.findNode(dirname) as DirectoryNode?;
    checkExists(node, () => dirname);
    utils.checkIsDir(node!, () => dirname);
    var tempCounter = _systemTempCounter[fileSystem] ?? 0;
    String name() => '$basename$tempCounter';
    while (node.children.containsKey(name())) {
      tempCounter++;
    }
    _systemTempCounter[fileSystem] = tempCounter;
    var tempDir = DirectoryNode(node);
    node.children[name()] = tempDir;
    return MemoryDirectory(fileSystem, fileSystem.path.join(dirname, name()))
      ..createSync();
  }

  @override
  Future<Directory> rename(String newPath) async => renameSync(newPath);

  @override
  Directory renameSync(String newPath) => internalRenameSync<DirectoryNode>(
        newPath,
        validateOverwriteExistingEntity: (DirectoryNode existingNode) {
          if (existingNode.children.isNotEmpty) {
            throw common.directoryNotEmpty(newPath);
          }
        },
      ) as Directory;

  @override
  Directory get parent =>
      (backingOrNull?.isRoot ?? false) ? this : super.parent;

  @override
  Directory get absolute => super.absolute as Directory;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) =>
      Stream<FileSystemEntity>.fromIterable(listSync(
        recursive: recursive,
        followLinks: followLinks,
      ));

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) {
    var node = backing as DirectoryNode;
    var listing = <FileSystemEntity>[];
    var tasks = <_PendingListTask>[
      _PendingListTask(
        node,
        path.endsWith(fileSystem.path.separator)
            ? path.substring(0, path.length - 1)
            : path,
        <LinkNode>{},
      ),
    ];
    while (tasks.isNotEmpty) {
      var task = tasks.removeLast();
      task.dir.children.forEach((String name, Node child) {
        var breadcrumbs = Set<LinkNode>.from(task.breadcrumbs);
        var childPath = fileSystem.path.join(task.path, name);
        while (followLinks &&
            utils.isLink(child) &&
            breadcrumbs.add(child as LinkNode)) {
          var referent = child.referentOrNull;
          if (referent != null) {
            child = referent;
          }
        }
        if (utils.isDirectory(child)) {
          listing.add(MemoryDirectory(fileSystem, childPath));
          if (recursive) {
            tasks.add(_PendingListTask(
                child as DirectoryNode, childPath, breadcrumbs));
          }
        } else if (utils.isLink(child)) {
          listing.add(MemoryLink(fileSystem, childPath));
        } else if (utils.isFile(child)) {
          listing.add(MemoryFile(fileSystem, childPath));
        }
      });
    }
    return listing;
  }

  @override
  @protected
  Directory clone(String path) => MemoryDirectory(fileSystem, path);

  @override
  String toString() => "MemoryDirectory: '$path'";
}

class _PendingListTask {
  _PendingListTask(this.dir, this.path, this.breadcrumbs);
  final DirectoryNode dir;
  final String path;
  final Set<LinkNode> breadcrumbs;
}
