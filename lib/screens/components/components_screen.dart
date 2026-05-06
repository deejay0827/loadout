import 'package:flutter/material.dart';

class ComponentsScreen extends StatelessWidget {
  const ComponentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        ListTile(leading: Icon(Icons.straighten), title: Text('Calibers')),
        ListTile(leading: Icon(Icons.adjust), title: Text('Bullets')),
        ListTile(leading: Icon(Icons.local_fire_department), title: Text('Powders')),
        ListTile(leading: Icon(Icons.flash_on), title: Text('Primers')),
        ListTile(leading: Icon(Icons.recycling), title: Text('Brass')),
      ],
    );
  }
}
