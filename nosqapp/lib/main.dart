import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:nostr_tools/nostr_tools.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  final FlutterSecureStorage secureStorage = const FlutterSecureStorage();

  Future<Widget> _getInitialPage() async {
    final storedNsec = await secureStorage.read(key: 'nsec');
    if (storedNsec != null) {
      return NotePage(userNsec: storedNsec);
    }
    return LoginPage();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nostr Note App',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Color(0xFF282828),
        appBarTheme: AppBarTheme(
          backgroundColor: Color(0xFF282828),
          elevation: 0,
        ),
        textTheme: TextTheme(
          bodyLarge: TextStyle(color: Color(0xFFEBDBB2)),
          bodyMedium: TextStyle(color: Color(0xFFEBDBB2)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFF98971A),
            foregroundColor: Color(0xFF282828),
            minimumSize: Size(double.infinity, 40),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        dialogBackgroundColor: Color(0xFF3C3836),
        colorScheme: ColorScheme.dark(
          primary: Color(0xFF98971A),
          onPrimary: Color(0xFF282828),
        ),
      ),
      home: FutureBuilder<Widget>(
        future: _getInitialPage(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          } else if (snapshot.hasError) {
            return Scaffold(
              body: Center(child: Text('An error occurred: ${snapshot.error}')),
            );
          } else {
            return snapshot.data!;
          }
        },
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _nsecController = TextEditingController();
  final FlutterSecureStorage secureStorage = const FlutterSecureStorage();

  Future<void> _navigateToNotePage() async {
    final userNsec = _nsecController.text.trim();
    if (userNsec.isEmpty || !userNsec.startsWith('nsec')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please enter a valid nsec starting with "nsec".')),
      );
      return;
    }

    try {
      final nip19 = Nip19();
      final decoded = nip19.decode(userNsec);
      if (decoded['type'] != 'nsec') {
        throw Exception('Invalid nsec format.');
      }
      await secureStorage.write(key: 'nsec', value: userNsec);

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => NotePage(userNsec: userNsec),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid nsec: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Login'),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nsecController,
                decoration: InputDecoration(
                  labelText: 'Enter your nsec...',
                  border: OutlineInputBorder(),
                  filled: true,
                  fillColor: Color(0xFF3C3836),
                  labelStyle: TextStyle(color: Color(0xFFEBDBB2)),
                  counterText: '',
                ),
                style: TextStyle(color: Color(0xFFEBDBB2)),
              ),
              SizedBox(height: 16),
              ElevatedButton(
                onPressed: _navigateToNotePage,
                child: Text('Login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NotePage extends StatefulWidget {
  final String userNsec;

  NotePage({required this.userNsec});

  @override
  _NotePageState createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> {
  final TextEditingController _noteController = TextEditingController();
  DateTime? _selectedDateTime;
  List<Map<String, dynamic>> _plannedNotes = [];
  final FlutterSecureStorage secureStorage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _loadPlannedNotes();
  }

  Future<void> _loadPlannedNotes() async {
    final storedNotes = await secureStorage.read(key: 'plannedNotes');
    if (storedNotes != null) {
      try {
        List<dynamic> decoded = json.decode(storedNotes);
        setState(() {
          _plannedNotes = decoded.map((note) => Map<String, dynamic>.from(note)).toList();
        });
      } catch (e) {}
    }
  }

  Future<void> _saveNote() async {
    final noteContent = _noteController.text.trim();
    if (noteContent.isEmpty || _selectedDateTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please enter a note and select a date/time.')),
      );
      return;
    }

    try {
      final nip19 = Nip19();
      final keyApi = KeyApi();
      final eventApi = EventApi();

      final decoded = nip19.decode(widget.userNsec);
      if (decoded['type'] != 'nsec') {
        throw Exception('The entered nsec is not valid.');
      }
      final privateKey = decoded['data'];

      final publicKey = keyApi.getPublicKey(privateKey);

      final scheduledTimestamp = _selectedDateTime!.millisecondsSinceEpoch ~/ 1000;

      final event = Event(
        kind: 1,
        tags: [
          ['scheduled', scheduledTimestamp.toString()],
        ],
        content: noteContent,
        created_at: scheduledTimestamp,
        pubkey: publicKey,
      );

      event.id = eventApi.getEventHash(event);
      event.sig = eventApi.signEvent(event, privateKey);

      if (!eventApi.verifySignature(event)) {
        throw Exception('Invalid signature.');
      }

      final broadcastId = event.id;

      final eventJson = json.encode(event.toJson());

      await _sendNoteToApi(broadcastId, _selectedDateTime!.toUtc().toIso8601String(), eventJson);

      setState(() {
        _plannedNotes.add({
          'broadcastId': broadcastId,
          'noteContent': noteContent,
          'plannedDate': _selectedDateTime!.toIso8601String(),
          'event': eventJson,
        });
        _noteController.clear();
        _selectedDateTime = null;
      });

      await secureStorage.write(
        key: 'plannedNotes',
        value: json.encode(_plannedNotes),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Note signed and saved successfully.')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save or send the note: $e')),
      );
    }
  }

  Future<void> _sendNoteToApi(String broadcastId, String plannedDate, String event) async {
    final url = Uri.parse('https://gutolcam.com:2121/api/notes');
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'broadcast_id': broadcastId,
          'planned_date': plannedDate,
          'event': event,
        }),
      );
      if (response.statusCode != 200) {
        throw Exception('Failed to send note: ${response.body}');
      }
    } catch (e) {
      throw Exception('Failed to send note: $e');
    }
  }

  Future<void> _selectDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDateTime ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (pickedDate != null) {
      final pickedTime = await showTimePicker(
        context: context,
        initialTime: _selectedDateTime != null
            ? TimeOfDay.fromDateTime(_selectedDateTime!)
            : TimeOfDay.now(),
      );

      if (pickedTime != null) {
        setState(() {
          _selectedDateTime = DateTime(
            pickedDate.year,
            pickedDate.month,
            pickedDate.day,
            pickedTime.hour,
            pickedTime.minute,
          );
        });
      }
    }
  }

  Future<void> _logout() async {
    await secureStorage.delete(key: 'nsec');
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => LoginPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.logout),
          onPressed: _logout,
        ),
        title: Text('Schedule Note'),
        actions: [
          IconButton(
            icon: Icon(Icons.list),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => PlannedNotesPage(notes: _plannedNotes)),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                TextField(
                  controller: _noteController,
                  decoration: InputDecoration(
                    labelText: 'Enter your note...',
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Color(0xFF3C3836),
                    labelStyle: TextStyle(color: Color(0xFFEBDBB2)),
                  ),
                  maxLines: 3,
                  style: TextStyle(color: Color(0xFFEBDBB2)),
                ),
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _selectDateTime,
                  child: Text(
                    _selectedDateTime == null
                        ? 'Select date and time'
                        : 'Selected: ${_selectedDateTime?.toLocal().toString().split('.')[0]}',
                  ),
                ),
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _saveNote,
                  child: Text('Schedule'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PlannedNotesPage extends StatelessWidget {
  final List<Map<String, dynamic>> notes;

  PlannedNotesPage({required this.notes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('Scheduled Notes'),
      ),
      body: Center(
        child: notes.isNotEmpty
            ? ListView.builder(
                itemCount: notes.length,
                itemBuilder: (context, index) {
                  final note = notes[index];
                  return Card(
                    color: Color(0xFF3C3836),
                    margin: EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                    child: ListTile(
                      title: Text(
                        note['noteContent'],
                        style: TextStyle(color: Color(0xFFEBDBB2)),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Scheduled Date: ${DateTime.parse(note['plannedDate']).toLocal().toString().split('.')[0]}',
                            style: TextStyle(color: Color(0xFFEBDBB2)),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Broadcast ID: ${note['broadcastId']}',
                            style: TextStyle(color: Color(0xFFEBDBB2)),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              )
            : Text(
                'No scheduled notes yet.',
                style: TextStyle(color: Color(0xFFEBDBB2)),
              ),
      ),
    );
  }
}
