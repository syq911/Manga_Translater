//
//  CategoryManagerView.swift
//  MangaTranslater
//
//  分类管理：新建 / 重命名 / 删除 / 排序。
//
//  分类是独立实体（见 `LibraryCategory`），所以这里可以创建**空分类**——
//  用户先建好「待读」「追更」之类的架子，再往里放书。
//
//  删除分类只把条目移出，不会删掉作品；界面文案要把这点说清楚，
//  否则用户不敢点。
//

import SwiftUI
import AppCore
import AppDatabase

struct CategoryManagerView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var categories: [LibraryCategory] = []
    @State private var counts: [String: Int] = [:]

    @State private var isCreating = false
    @State private var draftName = ""

    @State private var renamingCategory: LibraryCategory?
    @State private var renameDraft = ""

    @State private var message: String?

    var body: some View {
        List {
            Section {
                if categories.isEmpty {
                    Text(L("category.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(categories) { category in
                        row(for: category)
                    }
                    .onMove(perform: move)
                    .onDelete(perform: delete)
                }
            } footer: {
                Text(L("category.footer"))
            }
        }
        .navigationTitle(L("category.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    draftName = ""
                    isCreating = true
                } label: {
                    Label(L("category.create"), systemImage: "plus")
                }
            }
        }
        .onAppear(perform: reload)
        .alert(L("category.create"), isPresented: $isCreating) {
            TextField(L("category.name"), text: $draftName)
            Button(L("common.cancel"), role: .cancel) { draftName = "" }
            Button(L("category.create.action")) { create() }
        } message: {
            Text(L("category.create.message"))
        }
        .alert(L("category.rename"), isPresented: Binding(
            get: { renamingCategory != nil },
            set: { if !$0 { renamingCategory = nil } }
        )) {
            TextField(L("category.name"), text: $renameDraft)
            Button(L("common.cancel"), role: .cancel) { renamingCategory = nil }
            Button(L("common.save")) { rename() }
        } message: {
            Text(L("category.rename.message"))
        }
        .alert(L("common.notice"), isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button(L("common.ok"), role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: 子视图

    private func row(for category: LibraryCategory) -> some View {
        HStack {
            Text(category.name)
            Spacer()
            Text(String(format: L("category.count"), counts[category.id] ?? 0))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            renameDraft = category.name
            renamingCategory = category
        }
    }

    // MARK: 行为

    private func reload() {
        categories = (try? environment.libraryStore.categories()) ?? []
        let all = (try? environment.libraryStore.entries(sortedBy: .title, categoryID: nil)) ?? []
        counts = all.reduce(into: [String: Int]()) { result, entry in
            if let id = entry.categoryID {
                result[id, default: 0] += 1
            }
        }
    }

    private func create() {
        do {
            _ = try environment.libraryStore.createCategory(name: draftName)
            draftName = ""
            reload()
        } catch {
            message = (error as? LibraryStoreError)?.message ?? error.localizedDescription
        }
    }

    private func rename() {
        guard let target = renamingCategory else { return }
        do {
            _ = try environment.libraryStore.renameCategory(id: target.id, to: renameDraft)
            renamingCategory = nil
            reload()
        } catch {
            message = (error as? LibraryStoreError)?.message ?? error.localizedDescription
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = categories
        ordered.move(fromOffsets: source, toOffset: destination)
        do {
            try environment.libraryStore.reorderCategories(ordered.map(\.id))
            reload()
        } catch {
            message = (error as? LibraryStoreError)?.message ?? error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        var failures: [String] = []
        for index in offsets where categories.indices.contains(index) {
            do {
                _ = try environment.libraryStore.deleteCategory(id: categories[index].id)
            } catch {
                failures.append((error as? LibraryStoreError)?.message ?? error.localizedDescription)
            }
        }
        reload()
        if !failures.isEmpty {
            message = failures.joined(separator: "\n")
        }
    }
}

#Preview {
    NavigationStack {
        CategoryManagerView()
            .environment(AppEnvironment.makeDefault())
    }
}
