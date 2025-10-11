import 'package:flutter/material.dart';
import 'package:hoopsight/models/user_model.dart';
import 'package:hoopsight/services/auth_service.dart';
import 'package:hoopsight/services/user_service.dart';
import 'package:hoopsight/services/storage_service.dart';
import 'package:file_picker/file_picker.dart';

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final StorageService _storageService = StorageService();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();
  final TextEditingController _skillLevelController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  
  AppUser? _currentUser;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isUploadingPhoto = false;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  Future<void> _loadUserProfile() async {
    final firebaseUser = _authService.currentUser;
    if (firebaseUser != null) {
      final user = await _userService.getUser(firebaseUser.uid);
      if (user != null) {
        setState(() {
          _currentUser = user;
          _nameController.text = user.displayName;
          _bioController.text = user.bio ?? '';
          _skillLevelController.text = user.skillLevel;
          _phoneController.text = user.phoneNumber ?? '';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _uploadProfilePicture() async {
    if (_currentUser == null) return;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() => _isUploadingPhoto = true);
      try {
        final file = result.files.first;
        final photoUrl = await _storageService.uploadUserPhoto(_currentUser!.id, file.bytes!);
        
        final updatedUser = _currentUser!.copyWith(
          photoUrl: photoUrl,
          updatedAt: DateTime.now(),
        );
        
        await _userService.updateUser(updatedUser);
        setState(() => _currentUser = updatedUser);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile picture updated!')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Upload failed: $e')),
          );
        }
      } finally {
        setState(() => _isUploadingPhoto = false);
      }
    }
  }

  Future<void> _saveProfile() async {
    if (_currentUser == null) return;

    final newName = _nameController.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Display name cannot be empty')),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      if (newName.toLowerCase() != _currentUser!.displayName.toLowerCase()) {
        final isTaken = await _userService.isDisplayNameTaken(newName, excludeUserId: _currentUser!.id);
        if (isTaken) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Display name is already taken. Please choose another.')),
            );
          }
          return;
        }
      }

      final phoneNumber = _phoneController.text.trim();
      final updatedUser = _currentUser!.copyWith(
        displayName: newName,
        bio: _bioController.text.trim().isEmpty ? null : _bioController.text.trim(),
        skillLevel: _skillLevelController.text.trim(),
        phoneNumber: phoneNumber.isEmpty ? null : phoneNumber,
        updatedAt: DateTime.now(),
      );

      await _userService.updateUser(updatedUser);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated successfully')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update profile: $e')),
        );
      }
    } finally {
      setState(() => _isSaving = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    _skillLevelController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Profile'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _saveProfile,
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 60,
                    backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                    child: _currentUser?.photoUrl != null
                        ? ClipOval(
                            child: Image.network(
                              _currentUser!.photoUrl!,
                              width: 120,
                              height: 120,
                              fit: BoxFit.cover,
                            ),
                          )
                        : Icon(
                            Icons.person,
                            size: 60,
                            color: theme.colorScheme.primary,
                          ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: CircleAvatar(
                      backgroundColor: theme.colorScheme.primary,
                      radius: 20,
                      child: _isUploadingPhoto
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.camera_alt, size: 20, color: Colors.white),
                              onPressed: _uploadProfilePicture,
                            ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Display Name',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                hintText: 'Enter your name',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Bio',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _bioController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Tell us about yourself...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Phone Number (Optional)',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                hintText: '+1234567890',
                helperText: 'Help friends find you via their contacts',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Skill Level',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _skillLevelController.text.isEmpty ? 'Intermediate' : _skillLevelController.text,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              items: const [
                DropdownMenuItem(value: 'Beginner', child: Text('Beginner')),
                DropdownMenuItem(value: 'Intermediate', child: Text('Intermediate')),
                DropdownMenuItem(value: 'Advanced', child: Text('Advanced')),
                DropdownMenuItem(value: 'Pro', child: Text('Pro')),
              ],
              onChanged: (value) {
                if (value != null) {
                  _skillLevelController.text = value;
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
