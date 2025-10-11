# 🏀 HoopSight Support Page - Deployment Guide

## ✅ What's Been Created

I've created a professional support webpage for HoopSight that meets Apple's App Store requirements:

**Created Files:**
- `public/index.html` - Beautiful, responsive support page
- `public/firebase.json` - Firebase Hosting configuration
- `public/.firebaserc` - Firebase project reference

**Support Page Features:**
- ✅ Contact email: silverstreak622000@yahoo.com
- ✅ Support hours and response time information
- ✅ Comprehensive FAQ section (9 common questions)
- ✅ Contact form that saves messages to Firestore
- ✅ Privacy & Terms information
- ✅ Fully responsive design (mobile & desktop)
- ✅ Professional purple gradient branding matching your app

---

## 🚀 How to Deploy (3 Simple Steps)

### **Step 1: Install Firebase CLI**

If you haven't already, install Firebase CLI on your computer:

```bash
npm install -g firebase-tools
```

### **Step 2: Login to Firebase**

```bash
firebase login
```

This will open your browser to authenticate with your Google/Firebase account.

### **Step 3: Deploy the Support Page**

Navigate to the `public` folder and deploy:

```bash
cd public
firebase deploy --only hosting
```

**That's it!** Firebase will deploy your support page and give you a live URL like:

```
https://courthub-app.web.app
```

or

```
https://courthub-app.firebaseapp.com
```

---

## 📝 Update App Store Connect

Once deployed:

1. Go to [App Store Connect](https://appstoreconnect.apple.com)
2. Navigate to your HoopSight app
3. Go to **App Information**
4. Update the **Support URL** field with your Firebase Hosting URL
5. Save changes
6. Re-submit your app for review

---

## 📧 Managing Support Messages

When users submit the contact form, messages are saved to Firestore:

**Collection:** `support_messages`

**View Messages:**
1. Go to [Firebase Console](https://console.firebase.google.com)
2. Select your `courthub-app` project
3. Navigate to **Firestore Database**
4. Open the `support_messages` collection

**Message Structure:**
```json
{
  "name": "John Doe",
  "email": "user@example.com",
  "subject": "Question about check-ins",
  "message": "How do I check in with multiple players?",
  "timestamp": "2025-01-15T10:30:00Z"
}
```

---

## 🔧 Customization (Optional)

### Update Support Email

If you want to change the support email later, edit `public/index.html`:

1. Search for `silverstreak622000@yahoo.com`
2. Replace with new email address (appears in 3 places)
3. Re-deploy: `firebase deploy --only hosting`

### Add Custom Domain

To use a custom domain like `support.hoopsight.com`:

1. Go to Firebase Console > Hosting
2. Click "Add custom domain"
3. Follow the DNS configuration steps
4. Update App Store Connect with the custom URL

---

## ✅ Testing Before Deployment

Before deploying, you can test locally:

```bash
cd public
firebase serve
```

This will start a local server (usually at `http://localhost:5000`) where you can preview the support page.

---

## 🛡️ Firestore Security Rules

Make sure your Firestore has rules that allow the contact form to write:

```javascript
// In firestore.rules
match /support_messages/{messageId} {
  allow create: if true;  // Allow anyone to submit a message
  allow read, update, delete: if false;  // Only you can read via console
}
```

---

## 📱 What Apple Will See

When Apple reviews your app, they'll visit your support URL and see:

✅ **Contact Information** - Clear email and support hours  
✅ **FAQ Section** - 9 detailed answers to common questions  
✅ **Contact Form** - Users can submit questions directly  
✅ **Privacy Information** - Data collection and privacy details  
✅ **Professional Design** - Clean, mobile-friendly interface  

This meets all of Apple's Guideline 1.5 requirements!

---

## 🆘 Troubleshooting

### Error: "Firebase project not found"

**Solution:** Make sure you're in the `public` folder and run:
```bash
firebase use courthub-app
```

### Error: "Permission denied"

**Solution:** Make sure you're logged in:
```bash
firebase login
firebase projects:list
```

### Contact Form Not Working

**Solution:** 
1. Check Firebase Console > Firestore Database is enabled
2. Update Firestore security rules (see above)
3. Check browser console for errors

---

## 📞 Need Help?

If you encounter any issues deploying:

1. Check the [Firebase Hosting documentation](https://firebase.google.com/docs/hosting)
2. Verify your Firebase project is active in the console
3. Make sure billing is enabled (free tier is fine for this)

---

## 🎉 What's Next?

After deployment:

1. ✅ Get your Firebase Hosting URL
2. ✅ Update App Store Connect with the URL
3. ✅ Re-submit your app to Apple
4. ✅ Monitor support messages in Firestore
5. ✅ Respond to user emails at silverstreak622000@yahoo.com

---

**Your support page is ready to go! 🚀**
