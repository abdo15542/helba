# هلبة | HELBA

تطبيق مراسلة ليبي، بواجهة عربية RTL، مبني باستخدام Flutter وSupabase.

## الموجود في المستودع الآن
- تسجيل وإنشاء حساب بالبريد الإلكتروني وكلمة المرور فقط.
- اشتراط تأكيد البريد قبل السماح بالدخول.
- استعادة كلمة المرور عبر البريد.
- قفل البريد محلياً على تثبيت التطبيق باستخدام التخزين الآمن.
- شاشة صندوق وارد وبحث عن مستخدمين بالاسم أو اسم المستخدم.
- إنشاء محادثة مباشرة عبر RPC آمن.
- إرسال واستقبال الرسائل النصية عبر Supabase Realtime.
- ترحيل SQL لإنشاء المجموعات ومخزن خاص للمرفقات مع سياسات عضوية المحادثة.
- مخطط SQL وسياسات RLS للمراسلة.

## إعداد Flutter
يحتوي المستودع على ملفات التطبيق الأساسية. لتوليد ملفات منصات Flutter (ومنها Android) مرة واحدة:
```bash
flutter create --platforms=android,ios .
flutter pub get
```

شغّل التطبيق بمفاتيح مشروع Supabase:
```bash
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY
```

## إعداد Supabase
1. أنشئ مشروع Supabase.
2. شغّل `supabase/schema.sql` داخل SQL Editor.
3. فعّل تأكيد البريد الإلكتروني في Authentication.
4. شغّل ملف الترحيل `supabase/migrations/202611050001_profiles_and_direct_chat.sql` بعد المخطط الأساسي؛ ينشئ ملف المستخدم تلقائياً عند التسجيل ويعالج إنشاء المحادثة المباشرة المتزامن.
5. شغّل `supabase/migrations/202611050002_group_creation.sql` لإضافة إنشاء المجموعات بشكل آمن.
6. شغّل `supabase/migrations/202611050003_private_media_storage.sql` لإنشاء مخزن خاص للمرفقات وسياسات وصوله، وإضافة `messages` إلى Realtime تلقائياً.
7. راجع إعدادات SMTP وقوالب تأكيد البريد واستعادة كلمة المرور قبل فتح التسجيل للعامة.

## بناء APK
بعد توليد منصة Android وضبط مفاتيح Supabase:
```bash
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY
```

## الأمان وحدود النسخة
- لا تضع مفتاح `service_role` في التطبيق.
- قفل البريد الحالي مرتبط بتثبيت التطبيق؛ حذف بيانات التطبيق أو إعادة تثبيته قد يتجاوز القفل. منع ذلك يتطلب Device Attestation وربطاً خادمياً موثوقاً.
- واجهة رفع المرفقات لم تُربط بعد بمخزن الملفات؛ الترحيل يجهّز bucket خاصاً وسياسات الوصول فقط.
- واجهات المجموعات، القنوات، الحالات، المكالمات الصوتية/المرئية، إشعارات Push، التشفير الطرفي E2E ولوحة الإدارة ما زالت غير مكتملة.
- لم يتم إجراء بناء Flutter أو اختبار تكاملي على جهاز Android في هذه البيئة. اختبر SQL في مشروع Supabase قبل استخدامه مع بيانات حقيقية.
