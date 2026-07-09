import SwiftUI

// 2026-07 重设计（大梁老师拍板）：配方 = 名称 + 产物形态 + 一段 Prompt。
// 工程字段(处理策略/来源约束/输出结构/四段标准)全部收进内部自动决定；
// 模板库从双栏页面降级为编辑器里的「从模板开始」菜单。

/// 配方页：我的配方单列表（内置 + 自建），点编辑进单 Prompt 编辑器
struct ExtractionRecipesView: View {
    @Binding var recipeQuery: String
    @Binding var selectedRecipeID: String?
    let recipes: [ExtractionRecipe]
    let archivedRecipes: [ExtractionRecipe]
    let selectedRecipe: ExtractionRecipe?
    let onCreate: () -> Void
    let onEdit: (ExtractionRecipe) -> Void
    let onUseTemplates: ([ExtractionRecipe]) -> Void
    let onArchive: (ExtractionRecipe) -> Void
    let onRestore: (ExtractionRecipe) -> Void

    @State private var recipePendingArchive: ExtractionRecipe?
    @State private var isArchivedSectionExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 搜索框独占一行铺满；新建挪到页面右下角（2026-07-08 大梁老师）
            AssetLibrarySearchField(
                text: $recipeQuery,
                prompt: L("搜索配方", "Search recipes"),
                fill: TF.settingsDropdownTriggerFill
            )

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if recipes.isEmpty {
                        Text(L("还没有配方，点「新建」开始。", "No recipes yet — hit New to start."))
                            .font(TF.settingsFontBody)
                            .foregroundStyle(TF.settingsTextTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } else {
                        ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                            recipeRow(recipe)

                            if index < recipes.count - 1 {
                                Rectangle()
                                    .fill(TF.settingsStroke.opacity(0.14))
                                    .frame(height: 1)
                            }
                        }
                    }

                    if !archivedRecipes.isEmpty {
                        archivedSection
                    }
                }
                .padding(.bottom, SettingsScrollFade.contentPadding)
            }
            .settingsThinScrollIndicators()
            .settingsBottomScrollFade(color: AssetLibraryStyle.shellFill)

            HStack {
                Spacer(minLength: 0)
                SettingsTextButton(L("新建", "New"), variant: .primary, action: onCreate)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: AssetLibraryStyle.panelCornerRadius, style: .continuous)
                .fill(AssetLibraryStyle.shellFill)
        )
        .confirmationDialog(
            L("删除这个配方？", "Delete this recipe?"),
            isPresented: Binding(
                get: { recipePendingArchive != nil },
                set: { if !$0 { recipePendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("删除", "Delete"), role: .destructive) {
                if let recipe = recipePendingArchive {
                    onArchive(recipe)
                }
                recipePendingArchive = nil
            }
            Button(L("取消", "Cancel"), role: .cancel) {
                recipePendingArchive = nil
            }
        } message: {
            Text(L("删除后可在列表底部「最近删除」中恢复。", "Deleted recipes can be restored from Recently Deleted below."))
        }
    }
}

private extension ExtractionRecipesView {
    /// 配方行：细横线分隔的列表行，右侧操作按钮垂直居中
    func recipeRow(_ recipe: ExtractionRecipe) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(recipe.outputKind.settingsAccentColor)
                        .frame(width: 6, height: 6)

                    Text(recipe.name)
                        .font(TF.settingsFontBodyStrong)
                        .foregroundStyle(TF.settingsText)
                        .lineLimit(1)

                    Text(RecipeForm(outputKind: recipe.outputKind, strategy: recipe.processingStrategy).title)
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                }

                Text(recipe.unifiedPrompt)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(2)
                    .lineSpacing(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 内置/自建一视同仁都可删除（2026-07 大梁老师）；软删进「最近删除」可恢复
            SettingsTextButton(
                L("删除", "Delete"),
                variant: .secondary,
                controlSize: .compact
            ) {
                recipePendingArchive = recipe
            }

            SettingsTextButton(
                L("编辑", "Edit"),
                variant: .primary,
                controlSize: .compact
            ) {
                onEdit(recipe)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 最近删除折叠区：删除不等于丢失，可随时恢复（尤其内置配方的精调标准）
    @ViewBuilder
    var archivedSection: some View {
        SettingsSelectableRow(
            isSelected: false,
            minHeight: TF.settingsControlHeight,
            verticalPadding: 5
        ) {
            isArchivedSectionExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "archivebox")
                    .font(TF.settingsFontIconSmall)
                Text(L("最近删除 \(archivedRecipes.count) 个", "\(archivedRecipes.count) recently deleted"))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(TF.settingsFontIconSmall)
                    .frame(width: 10)
                    .rotationEffect(.degrees(isArchivedSectionExpanded ? 90 : 0))
            }
            .font(TF.settingsFontMetadata)
            .foregroundStyle(TF.settingsTextTertiary)
        }
        .padding(.top, 8)

        if isArchivedSectionExpanded {
            ForEach(archivedRecipes) { recipe in
                HStack(alignment: .center, spacing: 10) {
                    Circle()
                        .fill(recipe.outputKind.settingsAccentColor.opacity(0.5))
                        .frame(width: 6, height: 6)

                    Text(recipe.name)
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsTextSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    SettingsTextButton(
                        L("恢复", "Restore"),
                        variant: .secondary,
                        controlSize: .compact
                    ) {
                        onRestore(recipe)
                    }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 4)
                .opacity(0.85)
            }
        }
    }
}

// MARK: - 产物形态（用户唯一需要理解的分类：决定产物长什么样、内部自动定处理策略）

enum RecipeForm: String, CaseIterable, Identifiable {
    /// 素材卡片：金句/观点这类逐条淘金 → 全量分片扫描
    case card
    /// 行动清单：待办这类 → 整体阅读
    case list
    /// 整篇文档：日报/复盘/总结 → 整体阅读
    case document

    var id: String { rawValue }

    init(outputKind: ExtractionOutputKind, strategy: ExtractionProcessingStrategy) {
        switch outputKind {
        case .assetCandidates:
            self = .card
        case .todoList:
            self = .list
        case .dailyReport, .summary:
            self = .document
        case .custom:
            self = strategy == .mapReduce ? .card : .document
        }
    }

    var title: String {
        switch self {
        case .card: return L("素材卡片", "Cards")
        case .list: return L("行动清单", "Checklist")
        case .document: return L("整篇文档", "Document")
        }
    }

    var subtitle: String {
        switch self {
        case .card: return L("逐条淘金，如金句、观点", "Quotes, viewpoints")
        case .list: return L("逐项行动，如待办", "Todos")
        case .document: return L("整体成文，如日报、复盘", "Reports, reviews")
        }
    }

    /// 用户切换形态时写入的规范 outputKind
    var canonicalOutputKind: ExtractionOutputKind {
        switch self {
        case .card: return .assetCandidates
        case .list: return .todoList
        case .document: return .summary
        }
    }

    var strategy: ExtractionProcessingStrategy {
        self == .card ? .mapReduce : .whole
    }
}

// MARK: - 编辑器：名称 + 形态 + 一段 Prompt

struct ExtractionRecipeEditorSheet: View {
    let recipe: ExtractionRecipe?
    let onCancel: () -> Void
    let onSave: (ExtractionRecipe) -> Void

    @State private var name: String
    @State private var recipeDescription: String
    @State private var promptText: String
    @State private var form: RecipeForm

    init(
        recipe: ExtractionRecipe?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (ExtractionRecipe) -> Void
    ) {
        self.recipe = recipe
        self.onCancel = onCancel
        self.onSave = onSave

        _name = State(initialValue: recipe?.name ?? "")
        _recipeDescription = State(initialValue: recipe?.recipeDescription ?? "")
        _promptText = State(initialValue: recipe?.unifiedPrompt ?? "")
        _form = State(initialValue: recipe.map {
            RecipeForm(outputKind: $0.outputKind, strategy: $0.processingStrategy)
        } ?? .card)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(TF.settingsText)

                // 编辑时形态是配方天性、不可选，只作标签说明（2026-07 大梁老师：编辑金句不该看到清单/文档选项）
                if recipe != nil {
                    Text(form.title)
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(TF.settingsCardAlt)
                        )
                }

                Spacer(minLength: 8)

                templateMenu

                SettingsTextButton(L("取消", "Cancel"), variant: .secondary, onCanvas: true, action: onCancel)
                SettingsTextButton(L("保存", "Save"), variant: .primary, action: save)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.55)
            }

            HStack(alignment: .top, spacing: 10) {
                editorField(title: L("名称", "Name"), text: $name, height: 34)
                editorField(title: L("一句话说明（可选）", "Description (optional)"), text: $recipeDescription, height: 34)
            }


            VStack(alignment: .leading, spacing: 6) {
                Text(L("提炼 Prompt（用大白话写：提炼什么、什么算达标、什么不要）", "Prompt: what to extract, what qualifies, what to drop"))
                    .font(TF.settingsFontMetadata)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.leading, 9)

                TextEditor(text: $promptText)
                    .font(TF.settingsFontReading)
                    .foregroundStyle(TF.settingsText)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius, style: .continuous)
                            .fill(TF.settingsDropdownTriggerFill)
                    )
            }
            .frame(maxHeight: .infinity)
        }
        .padding(18)
        .frame(width: 640, height: 620, alignment: .topLeading)
        .background(TF.settingsCanvas)
    }

    private var title: String {
        recipe == nil ? L("新建配方", "New recipe") : L("编辑配方", "Edit recipe")
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 从模板开始：16 个出厂模板一键填充，可再改
    private var templateMenu: some View {
        Menu {
            ForEach(AssetDefinitionTemplateGroup.defaults()) { group in
                Section(group.name) {
                    ForEach(group.templates) { template in
                        Button(template.name) {
                            applyTemplate(template)
                        }
                    }
                }
            }
        } label: {
            Text(L("模板", "Templates"))
                .font(TF.settingsFontControl)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func applyTemplate(_ template: ExtractionRecipe) {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = template.name
        }
        recipeDescription = template.recipeDescription
        promptText = template.unifiedPrompt
        // 新建时形态跟模板走；编辑已有配方时形态保留配方原值(save 不读 form)
        if recipe == nil {
            form = RecipeForm(outputKind: template.outputKind, strategy: template.processingStrategy)
        }
    }

    private func editorField(title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.leading, 9)

            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(TF.settingsFontReading)
                .foregroundStyle(TF.settingsText)
                .padding(.horizontal, 9)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius, style: .continuous)
                        .fill(TF.settingsDropdownTriggerFill)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = recipeDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 编辑时形态不可改：outputKind/strategy 全部保留原值；只有新建才由三选决定
        let outputKind: ExtractionOutputKind
        if let recipe {
            outputKind = recipe.outputKind
        } else {
            outputKind = form.canonicalOutputKind
        }
        let destination = destination(for: outputKind)

        // 单 Prompt 收拢：全文存 goalPrompt，四段旧字段清空——用户看到的即生效的
        if let recipe {
            onSave(recipe.updating(
                name: trimmedName,
                recipeDescription: trimmedDescription,
                goalPrompt: trimmedPrompt,
                outputKind: outputKind,
                processingStrategy: recipe.processingStrategy,
                sourcePolicy: recipe.sourcePolicy,
                outputSchema: recipe.outputSchema,
                qualityRules: "",
                saveRule: "",
                ignoreRule: "",
                destination: destination,
                status: .active
            ))
        } else {
            onSave(ExtractionRecipe.custom(
                name: trimmedName,
                recipeDescription: trimmedDescription,
                goalPrompt: trimmedPrompt,
                outputKind: outputKind,
                processingStrategy: form.strategy,
                sourcePolicy: .evidenceRequired,
                qualityRules: "",
                destination: destination
            ))
        }
    }

    private func destination(for kind: ExtractionOutputKind) -> ExtractionDestination {
        switch kind {
        case .todoList:
            return .todoList
        case .dailyReport:
            return .document
        case .assetCandidates:
            return .assetCandidatePool
        case .summary, .custom:
            return .resultArchive
        }
    }
}
