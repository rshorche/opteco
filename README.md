# Opteco

پلتفرم تحلیل، پیشنهاد و مدیریت استراتژی‌های اختیار معامله در بازار سرمایه ایران.
نسخهٔ فعلی: **MVP — فقط Covered Call**.

## وضعیت فعلی پروژه: پایان Phase 0

| فاز | وضعیت |
|---|---|
| Phase 0 — زیرساخت Repo/Environment | ✅ همین Commit |
| Phase 1 — Auth واقعی | ⏳ بعدی |
| Phase 2 — اتصال Market API واقعی | ⏳ در انتظار تعیین Provider |
| Phase 3 — Suggestion Engine واقعی | ⏳ |
| Phase 4 — Vertical Slice Dashboard | ⏳ |
| Phase 5 — ثبت معاملهٔ واقعی | ⏳ (Backend آماده، UI باقی مانده) |

## ساختار Repo

```
opteco/
├── app/
│   ├── api/
│   │   ├── positions/                # ساخت Position (fn_create_position)
│   │   │   └── executions/           # ثبت INCREASE/DECREASE/CLOSE
│   │   ├── strategy/initial-entry/   # fn_record_initial_entry
│   │   └── covered-call/suggestions/ # Suggestion Engine (منطق آماده، اتصال API واقعی باقی مانده)
│   ├── (auth)/                       # صفحات ورود/ثبت‌نام — Phase 1
│   └── (dashboard)/                  # داشبورد کاربر — Phase 4
├── lib/
│   ├── supabase/                     # Client factoryها (service-role / user-scoped)
│   ├── strategy/
│   │   ├── covered-call/             # الگوریتم Candidate Selection + Ranking
│   │   └── lifecycle/                # Wrapper تایپ‌شده روی RPCهای اتمیک Lifecycle
│   └── market-data/                  # Adapter Market API — Phase 2 (هنوز خالی)
├── db/
│   └── migrations/
│       ├── 001_initial_schema.sql    # هستهٔ کامل Schema (۲۵+ جدول، ۷ دامنه)
│       └── 002_rpc_lifecycle.sql     # RPCهای اتمیک + Hardening کامل (امنیت/Consistency)
├── .env.local.example
└── .gitignore
```

## Environmentها

| Environment | پروژهٔ Supabase | نکته |
|---|---|---|
| Development | `opteco-test` | فقط برای تست؛ چون در پلن فعلی هم‌زمان حداکثر ۲ پروژه فعال مجاز است، وقتی لازم شد باید `opteco` (Production) موقتاً از داشبورد Supabase غیرفعال و `opteco-test` فعال شود، و بعد از پایان تست دوباره برعکس. |
| Production | `opteco` | تازه‌ساز و تمیز (صفر جدول)؛ Migration هنوز روی آن اجرا نشده — منتظر تأیید شماست (ذیل «تصمیم‌های باز»). |

مقادیر واقعی هرگز در Git ذخیره نمی‌شوند — فقط در Environment Variables خودِ Vercel (جدا برای Development/Preview/Production) و `.env.local` محلی (که در `.gitignore` است).

## وضعیت Migrationها

هر دو فایل داخل `db/migrations/` دقیقاً همان نسخه‌ای هستند که روی `opteco-test` به‌طور کامل اجرا و تست شدند (شامل تمام Reviewهای امنیتی/Consistency قبلی: RLS کامل، RPCهای SECURITY DEFINER، Constraint Trigger برای صحت Ledger معاملات، Collateral Snapshot خودکار). **هنوز روی پروژهٔ Production (`opteco`) اجرا نشده‌اند** — این کار به‌عنوان اولین قدم Phase 1 (همراه با Trigger اتصال `auth.users`) انجام خواهد شد، مگر این‌که ترجیح بدهید زودتر انجام شود.

## قواعد ثابت پروژه (از مراحل قبلی)

- منطق تخصصی بازار اختیار ایران (فرمول‌ها، تعاریف) از Skill `Iran Options` می‌آید، نه از این Repo.
- دادهٔ لحظه‌ای بازار هرگز به‌عنوان Knowledge/Cache دائمی ذخیره نمی‌شود.
- تنها مسیر نوشتن روی جداول حساس Lifecycle، RPCهای اتمیک `db/migrations/002_rpc_lifecycle.sql` هستند (نه INSERT/UPDATE مستقیم).
- معماری از ابتدا Multi-Strategy و Subscription-aware است؛ MVP فعلی عمداً فقط روی Covered Call متمرکز است.
