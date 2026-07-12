# Flowe — Build Progress

## Phase 1 — Bootstrap, Design System, Onboarding & Auth
- [x] Xcode project generated via xcodegen
- [x] Design system: FlowColor (12 tokens), FlowTypography, FlowSpacing, FlowGradients
- [x] Extensions: Color+Flowe, View+Flowe, Date+Flowe
- [x] AppSession (@Observable auth state machine)
- [x] AppRouter (switches onboarding ↔ tab shells)
- [x] UI atoms: PrimaryButton, SecondaryButton, IconButton
- [x] UI atoms: FloatingLabelField, DisciplineTag
- [x] Onboarding: SplashView (2s auto-advance, spring entrance)
- [x] Onboarding: RoleSelectionView (Learn / Teach cards)
- [x] Onboarding: CreateAccountView (form + Apple Sign-In)
- [x] Onboarding: LoginView (form + Apple Sign-In)
- [x] Tab shell stubs: StudentTabView, InstructorTabView
- [x] Models: User, UserRole, AuthState

## Phase 2 — Student Core (Home, Map, Profile)
- [ ] StudentTabView — 4 tabs wired to real screens
- [ ] InstructorCard component
- [ ] AvatarView component
- [ ] StarRatingView component
- [ ] StatTileView component
- [ ] SectionHeader component
- [ ] FilterChipsBar component
- [ ] StudentHomeView + InstructorDetailView
- [ ] StudentHomeViewModel
- [ ] MapSearchView + PricePinAnnotation
- [ ] MapSearchViewModel
- [ ] LocationService
- [ ] StudentProfileView
- [ ] StudentProfileViewModel
- [ ] instructors.json mock data (8–10 entries)

## Phase 3 — Instructor Core (Dashboard, Calendar, Profile)
- [ ] InstructorTabView — 5 tabs wired to real screens
- [ ] SessionCard component
- [ ] QuickActionsGrid component
- [ ] WeeklyGridView (custom drawn)
- [ ] InstructorDashboardView
- [ ] InstructorDashboardViewModel
- [ ] InstructorCalendarView
- [ ] BookingRequestsSheet
- [ ] InstructorCalendarViewModel
- [ ] InstructorProfileView (Overview / Analytics / Reviews / Earnings tabs)
- [ ] AvailabilityView
- [ ] EarningsView (manual bar chart)
- [ ] InstructorProfileViewModel
- [ ] sessions.json mock data

## Phase 4 — Shared Screens (Community Hub, Messages)
- [ ] CommunityHubView
- [ ] PostRowView
- [ ] CommentSheetView
- [ ] ComposePostSheet (PhotosUI)
- [ ] CommunityViewModel
- [ ] MessageListView
- [ ] ConversationView
- [ ] MessageBubble
- [ ] MessagesViewModel
- [ ] posts.json, events.json, conversations.json

## Phase 5 — Polish (Animations, Empty States, Loading)
- [ ] Transitions: splash spring, role card slide-in, auth-state switch
- [ ] Hero transition: matchedGeometryEffect InstructorCard → Detail
- [ ] Micro-interactions: heart KeyframeAnimator, stat tile count-up
- [ ] EmptyStateView (Home, Map, Calendar, Messages, Community)
- [ ] ShimmerView skeleton loading
- [ ] .floweBackground() on all top-level screens
- [ ] Tab bar ultraThinMaterial tint
- [ ] Accessibility labels/hints on all interactive elements
- [ ] Layout verified on iPhone 15 Pro + iPhone SE
- [ ] Dynamic Type XL verified
