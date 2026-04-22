# NeuType 权限 / 签名 / 测试包运行规范

本文档定义 NeuType 测试包与正式包的权限验证流程，目标是：

- 测试包的授权流程稳定可复现
- Screen Recording / Screen & System Audio Recording 不再因为包身份混乱而失效
- 正式包权限验证与测试包完全隔离，避免 TCC 污染

---

## 1. 已确认的问题根因

历史问题不是单点故障，而是以下三类问题叠加：

1. 同一机器上存在多份 `NeuType-Test.app`
   - `DerivedData/.../NeuType-Test.app`
   - `build/.../NeuType-Test.app`
   - `.local-debug-dd/.../NeuType-Test.app`
   - 系统设置、LaunchServices、TCC 会被同名副本干扰

2. 测试包有时是 ad-hoc 签名
   - `Signature=adhoc`
   - `TeamIdentifier=not set`
   - 这类包去申请 Screen Recording 时，系统设置里可能不正常登记

3. Screen Recording 属于“授权后需要重启进程才能稳定生效”的权限
   - 不能按普通即时权限处理
   - 必须显式维护 `needsAuthorization -> needsRelaunch -> granted` 状态机

---

## 2. 目标包身份

### 2.1 测试包

- Bundle ID：`ai.neuxnet.neutype.test`
- Display Name：`NeuType-Test`
- 签名：`Apple Development`
- Team ID：`4URL8287A7`
- 唯一允许使用的路径：
  - `build/Build/Products/Debug/NeuType-Test.app`

### 2.2 正式包

- Bundle ID：`ai.neuxnet.neutype`
- Display Name：`NeuType`
- 签名：
  - 本地开发验证：`Apple Development`
  - 对外分发：`Developer ID` 或正式发布签名
- 正式包与测试包必须使用不同 Bundle ID，确保 TCC 完全隔离

---

## 3. 测试包运行规范

### 3.1 唯一测试入口

测试包只允许通过一个入口构建和启动：

- `./run.sh`
- 或 `./run.sh build` 后手动打开：
  - `build/Build/Products/Debug/NeuType-Test.app`

禁止：

- 直接双击 `DerivedData/.../NeuType-Test.app`
- 直接打开 `.local-debug-dd/.../NeuType-Test.app`
- 保留多份同名测试包并混用

### 3.2 启动前清理规范

每次做“干净权限验证”前，必须执行：

1. 杀掉所有 `NeuType-Test` 进程
2. 删除所有非标准路径的测试包副本
   - `~/Library/Developer/Xcode/DerivedData/.../NeuType-Test.app`
   - `.local-debug-dd/.../NeuType-Test.app`
3. 只保留：
   - `build/Build/Products/Debug/NeuType-Test.app`
4. 如需重测权限，重置测试包的 TCC：
   - `tccutil reset Microphone ai.neuxnet.neutype.test`
   - `tccutil reset Accessibility ai.neuxnet.neutype.test`
   - `tccutil reset ScreenCapture ai.neuxnet.neutype.test`
5. 重置本地权限状态偏好：
   - `didPromptForScreenRecordingPermission = false`
   - `screenRecordingPermissionPendingRelaunch = false`

### 3.3 启动前签名校验

启动测试包前必须检查：

- `codesign -dv build/Build/Products/Debug/NeuType-Test.app`

必须满足：

- `Identifier=ai.neuxnet.neutype.test`
- `TeamIdentifier=4URL8287A7`
- 不能是 `Signature=adhoc`

若不满足，则该构建视为无效测试包，不允许用于权限验证。

---

## 4. 应用内权限状态机

权限统一由 `PermissionsManager` 提供状态，所有页面共用同一套来源。

### 4.1 Microphone

状态规则：

- 未授权：显示 `Grant Access`
- 已授权：显示 `granted`

行为规则：

- 首次申请：走系统麦克风授权
- 已拒绝：继续显示 `Grant Access`，并允许打开系统设置

### 4.2 Accessibility

状态规则：

- 未授权：显示 `Grant Access`
- 已授权：显示 `granted`

行为规则：

- 通过 `AXIsProcessTrusted` 轮询状态
- 一般不要求 app relaunch

### 4.3 Screen Recording / Screen & System Audio Recording

这是最严格的权限链路。状态只允许三种：

- `needsAuthorization`
- `needsRelaunch`
- `granted`

#### `needsAuthorization`

进入条件：

- `CGPreflightScreenCaptureAccess() == false`
- 且 `screenRecordingPermissionPendingRelaunch == false`

UI：

- 按钮显示 `Grant Access`

点击后：

1. 调用 `CGRequestScreenCaptureAccess()`
2. 打开系统设置到 Screen Recording 页面
3. 设置：
   - `screenRecordingPermissionPendingRelaunch = true`

#### `needsRelaunch`

进入条件：

- `screenRecordingPermissionPendingRelaunch == true`

UI：

- 按钮显示 `Relaunch`
- 文案显示“已授权，重启后生效”或“等待重启完成授权链路”

行为约束：

- 此状态下不能再次显示 `Grant Access`
- 此状态下不能再次走 `CGRequestScreenCaptureAccess()`
- 只允许引导用户重启应用

#### `granted`

进入条件：

- 重启后再次检查
- `CGPreflightScreenCaptureAccess() == true`

进入后必须清理：

- `screenRecordingPermissionPendingRelaunch = false`
- `didPromptForScreenRecordingPermission = false`

---

## 5. Screen Recording UI 规则

主权限页、设置页、任何权限摘要 UI 都必须共用同一套屏幕录制状态，不允许各自推导。

### 5.1 Screen Recording 行为映射

- `needsAuthorization` -> 按钮 `Grant Access`
- `needsRelaunch` -> 按钮 `Relaunch`
- `granted` -> 无按钮

### 5.2 明确禁止的错误行为

以下行为视为 bug：

1. 系统设置里已经授权，但 UI 仍显示 `Grant Access`
2. `screenRecordingPermissionPendingRelaunch == true`，但 UI 退回 `Grant Access`
3. 已进入 `needsRelaunch`，点击按钮却再次尝试申请权限
4. 首屏因为异步状态回填竞态，短暂错误显示“未授权”

---

## 6. 正式包权限验证规范

正式包不能依赖测试包的 TCC 结果，必须单独验证。

### 6.1 正式包基本要求

- Bundle ID：`ai.neuxnet.neutype`
- 使用正式签名链
- 不允许使用 ad-hoc 构建做正式权限验收

### 6.2 正式包权限验收步骤

1. 安装正式包
2. 重置正式包 Bundle ID 对应的 TCC 记录
3. 从零开始验证：
   - 麦克风
   - Accessibility
   - Screen Recording
4. 对 Screen Recording 执行完整链路：
   - 未授权
   - 点击申请
   - 系统设置授权
   - app 重启
   - 重启后变为 `granted`
5. 通过后才允许发布

---

## 7. 工程硬约束

### 7.1 测试包只允许保留一个有效产物

推荐唯一有效路径：

- `build/Build/Products/Debug/NeuType-Test.app`

其他同名 app 必须删除或忽略，不允许参与测试。

### 7.2 `run.sh` 是标准本地测试入口

`run.sh` 应负责：

- 构建测试包
- 校验签名
- 清理旧 app 副本
- 清理本地状态
- 重置测试包 TCC
- 启动唯一正确的测试包

### 7.3 启动前必须硬校验包身份

若以下任一条件不满足，直接判定为错误包：

- Bundle ID 不是 `ai.neuxnet.neutype.test`
- Team ID 不是 `4URL8287A7`
- `Signature=adhoc`

### 7.4 权限状态机必须有回归测试

至少覆盖以下 case：

1. Screen Recording 初次未授权 -> `Grant Access`
2. 点击后 pending -> `Relaunch`
3. pending 存在时，不能退回 `Grant Access`
4. 重启后 preflight true -> `granted`
5. 已授权启动时，首屏不能因为异步竞态错误显示未授权

---

## 8. 当前执行标准

### 测试包标准动作

1. 只构建 `build/Build/Products/Debug/NeuType-Test.app`
2. 删除其他测试包副本
3. 验证签名不是 ad-hoc
4. 重置测试 Bundle ID 的 TCC
5. 启动 app
6. 用户完成授权
7. Screen Recording 进入 `needsRelaunch`
8. 重启 app
9. 重启后进入 `granted`

### 正式包标准动作

1. 使用正式 Bundle ID 构建或导出
2. 使用正式分发签名
3. 单独重置正式 Bundle ID 的 TCC
4. 从零验证完整授权链路
5. 验证通过后再发布

---

## 9. 后续建议

建议后续继续落地以下工程改进：

1. `run.sh` 启动前自动删除 `DerivedData` 中所有 `NeuType-Test.app`
2. `run.sh` 启动前强制校验签名链，发现 ad-hoc 直接失败
3. `.local-debug-dd` 中不再保留可执行测试 app，避免误启动
4. 正式包增加一份独立的权限验收 checklist

