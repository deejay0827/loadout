import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/load.dart';
import '../../repositories/load_repository.dart';

class LoadsListScreen extends StatelessWidget {
  const LoadsListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<LoadRepository>();
    return StreamBuilder<List<Load>>(
      stream: repo.watchAll(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final loads = snapshot.data ?? [];
        if (loads.isEmpty) {
          return const Center(child: Text('No loads yet.'));
        }
        return ListView.builder(
          itemCount: loads.length,
          itemBuilder: (context, i) {
            final load = loads[i];
            return ListTile(
              title: Text(load.name),
              subtitle: Text('${load.powderChargeGr} gr @ ${load.coalIn}" COAL'),
            );
          },
        );
      },
    );
  }
}
