// ============================================================
// PLC控制器结构化文本(ST)学习示例
// 包含基础语法到高级工业控制应用
// 适用控制器：Codesys, TwinCAT, Siemens S7-1500/1200
// ============================================================

//------------------------------------------------------------------------
// 1. 程序组织单元(POU) - 基本结构
//------------------------------------------------------------------------

// 功能块定义
FUNCTION_BLOCK FB_MotorControl
// 输入变量
VAR_INPUT
    StartCmd      : BOOL;      // 启动命令
    StopCmd       : BOOL;      // 停止命令
    SpeedRef      : REAL;      // 速度给定
    CurrentFeedback : REAL;    // 电流反馈
END_VAR

// 输出变量
VAR_OUTPUT
    MotorRun      : BOOL;      // 电机运行状态
    SpeedActual   : REAL;      // 实际速度
    CurrentAlarm  : BOOL;      // 电流报警
    FaultCode     : WORD;      // 故障代码
END_VAR

// 内部变量
VAR
    RunTimer      : TON;       // 运行定时器
    OverCurrentCnt : INT;      // 过流计数
    InternalState : INT;       // 内部状态
END_VAR

// 静态变量（保持型）
VAR RETAIN
    RunHours      : REAL;      // 运行小时数
    TotalStarts   : DINT;      // 总启动次数
END_VAR

// 常量定义
VAR CONSTANT
    MAX_CURRENT   : REAL := 10.5;     // 最大电流
    OVERCURRENT_LIMIT : INT := 3;      // 过流限制次数
END_VAR

//------------------------------------------------------------------------
// 功能块主体代码
//------------------------------------------------------------------------

// 电机启动/停止逻辑
IF StartCmd AND NOT StopCmd THEN
    MotorRun := TRUE;
    TotalStarts := TotalStarts + 1;  // 累计启动次数
ELSIF StopCmd THEN
    MotorRun := FALSE;
END_IF

// 速度控制
IF MotorRun THEN
    SpeedActual := SpeedRef * 0.95;  // 模拟实际速度
    
    // 电流监控
    IF CurrentFeedback > MAX_CURRENT THEN
        OverCurrentCnt := OverCurrentCnt + 1;
    ELSE
        OverCurrentCnt := 0;
    END_IF
    
    // 过流保护
    IF OverCurrentCnt >= OVERCURRENT_LIMIT THEN
        CurrentAlarm := TRUE;
        MotorRun := FALSE;           // 停机保护
        FaultCode := 16#1001;        // 过流故障代码
    END_IF
    
    // 累计运行时间
    RunTimer(IN := TRUE, PT := T#1h);
    IF RunTimer.Q THEN
        RunHours := RunHours + 1.0;
        RunTimer(IN := FALSE);       // 复位定时器
    END_IF
ELSE
    SpeedActual := 0.0;
    OverCurrentCnt := 0;
    RunTimer(IN := FALSE);
END_IF

//------------------------------------------------------------------------
// 2. 程序组织单元 - 函数
//------------------------------------------------------------------------

FUNCTION FC_CalculatePID : REAL
// PID控制器函数
VAR_INPUT
    Setpoint      : REAL;      // 设定值
    ProcessValue  : REAL;      // 过程值
    Kp            : REAL;      // 比例增益
    Ki            : REAL;      // 积分增益
    Kd            : REAL;      // 微分增益
    DeltaTime     : TIME;      // 采样时间
END_VAR

VAR_IN_OUT
    IntegralPart  : REAL;      // 积分部分（保持）
    LastError     : REAL;      // 上次误差（保持）
END_VAR

VAR
    Error         : REAL;
    Proportional  : REAL;
    Derivative    : REAL;
    dt            : REAL;
END_VAR

// 计算误差
Error := Setpoint - ProcessValue;

// 比例项
Proportional := Kp * Error;

// 积分项
dt := TIME_TO_REAL(DeltaTime) / 1000.0;  // 转换为秒
IntegralPart := IntegralPart + Ki * Error * dt;

// 微分项
Derivative := Kd * (Error - LastError) / dt;

// PID输出
FC_CalculatePID := Proportional + IntegralPart + Derivative;

// 保存上次误差
LastError := Error;

END_FUNCTION

//------------------------------------------------------------------------
// 3. 程序组织单元 - 主程序
//------------------------------------------------------------------------

PROGRAM MainProgram
// 全局变量引用
VAR_GLOBAL
    SystemReady   : BOOL;
    EmergencyStop : BOOL;
    ConveyorSpeed : REAL;
END_VAR

// 本地变量
VAR
    // 电机控制实例
    Motor1        : FB_MotorControl;
    Motor2        : FB_MotorControl;
    
    // 定时器
    CycleTimer    : TP;         // 脉冲定时器
    WatchdogTimer : TOF;        // 关断延时定时器
    BlinkTimer    : BLINK;      // 闪烁定时器
    
    // 计数器
    PartCounter   : CTUD;       // 双向计数器
    TotalParts    : INT;
    
    // PID控制
    PID_Integral  : REAL := 0.0;
    PID_LastError : REAL := 0.0;
    PID_Output    : REAL;
    
    // 数组
    Temperature   : ARRAY[1..6] OF REAL;  // 6个温度传感器
    PressureHistory : ARRAY[0..99] OF REAL; // 压力历史
    
    // 枚举类型
    TYPE MachineState : (ST_IDLE, ST_START, ST_RUN, ST_STOP, ST_FAULT);
    CurrentState : MachineState;
    
    // 结构体
    TYPE ProductInfo :
    STRUCT
        ProductID   : DINT;
        ProductName : STRING(20);
        TargetWeight : REAL;
        ActualWeight : REAL;
        IsPass      : BOOL;
    END_STRUCT;
    
    CurrentProduct : ProductInfo;
    
    // 联合体
    TYPE DataWord :
    UNION
        Value       : WORD;
        Bits        : ARRAY[0..15] OF BOOL;
    END_UNION;
    
    StatusWord : DataWord;
    
    // 其他变量
    i, j          : INT;
    ScanCounter   : UDINT := 0;
    StartTime     : TIME;
END_VAR

//------------------------------------------------------------------------
// 主程序代码
//------------------------------------------------------------------------

// 初始化
IF NOT SystemReady THEN
    CurrentState := ST_IDLE;
    StartTime := TIME();
    ScanCounter := 0;
END_IF

// 主循环计数
ScanCounter := ScanCounter + 1;

// 紧急停止处理
IF EmergencyStop THEN
    CurrentState := ST_STOP;
    Motor1(StartCmd := FALSE, StopCmd := TRUE);
    Motor2(StartCmd := FALSE, StopCmd := TRUE);
END_IF

// 状态机 - 控制系统流程
CASE CurrentState OF
    
    ST_IDLE:
        // 空闲状态
        IF SystemReady AND NOT EmergencyStop THEN
            CurrentState := ST_START;
            // 初始化产品信息
            CurrentProduct.ProductID := 1001;
            CurrentProduct.ProductName := 'Widget';
            CurrentProduct.TargetWeight := 100.0;
        END_IF
    
    ST_START:
        // 启动状态
        Motor1(StartCmd := TRUE, SpeedRef := 50.0);
        Motor2(StartCmd := TRUE, SpeedRef := 30.0);
        
        // 延时启动完成检测
        CycleTimer(IN := TRUE, PT := T#5s);
        IF CycleTimer.Q THEN
            CurrentState := ST_RUN;
            CycleTimer(IN := FALSE);
        END_IF
    
    ST_RUN:
        // 运行状态
        // 读取温度传感器
        FOR i := 1 TO 6 DO
            Temperature[i] := Temperature[i] * 0.9 + 25.0 * 0.1; // 模拟温度
        END_FOR
        
        // 温度平均值检查
        IF Temperature[1] > 30.0 THEN
            StatusWord.Bits[0] := TRUE;  // 温度报警位
        ELSE
            StatusWord.Bits[0] := FALSE;
        END_IF
        
        // PID控制示例
        PID_Output := FC_CalculatePID(
            Setpoint := 100.0,
            ProcessValue := ConveyorSpeed,
            Kp := 1.5,
            Ki := 0.1,
            Kd := 0.05,
            DeltaTime := T#100ms,
            IntegralPart := PID_Integral,
            LastError := PID_LastError
        );
        
        // 闪烁指示器
        BlinkTimer(ENABLE := TRUE, TIMELOW := T#500ms, TIMEHIGH := T#500ms);
        StatusWord.Bits[1] := BlinkTimer.OUT;
        
        // 产品计数
        IF Temperature[2] > 25.0 THEN
            PartCounter(CU := TRUE, RESET := FALSE);  // 加计数
            TotalParts := PartCounter.CV;
        END_IF
        
        // 压力历史记录
        FOR j := 99 DOWNTO 1 DO
            PressureHistory[j] := PressureHistory[j-1];
        END_FOR
        PressureHistory[0] := Temperature[3] * 0.8;  // 模拟压力
        
        // 检查是否停止
        IF StopCmd THEN
            CurrentState := ST_STOP;
        END_IF
    
    ST_STOP:
        // 停止状态
        Motor1(StopCmd := TRUE);
        Motor2(StopCmd := TRUE);
        
        WatchdogTimer(IN := Motor1.MotorRun, PT := T#2s);
        IF NOT WatchdogTimer.Q THEN
            CurrentState := ST_IDLE;
        END_IF
    
    ST_FAULT:
        // 故障状态
        // 记录故障时间
        FaultTime := TIME();
        // 等待复位
        IF SystemReady THEN
            CurrentState := ST_IDLE;
        END_IF
    
END_CASE

// 看门狗监控
WatchdogTimer(IN := SystemReady, PT := T#1s);
IF NOT WatchdogTimer.Q THEN
    StatusWord.Bits[2] := TRUE;  // 看门狗超时
ELSE
    StatusWord.Bits[2] := FALSE;
END_IF

// 数据记录
IF ScanCounter MOD 1000 = 0 THEN
    // 每1000个扫描周期记录一次数据
    WriteDataToHMI(CurrentState, Temperature[1], TotalParts);
END_IF

// 安全逻辑
IF Temperature[1] > 50.0 OR Temperature[2] > 50.0 THEN
    CurrentState := ST_FAULT;
    StatusWord.Bits[3] := TRUE;  // 超温故障
END_IF

//------------------------------------------------------------------------
// 4. 函数块实例化 - 模拟输入处理
//------------------------------------------------------------------------

FUNCTION_BLOCK FB_AnalogInput
VAR_INPUT
    RawValue      : INT;        // 原始AD值
    ScalingFactor : REAL;        // 缩放因子
    Offset        : REAL;        // 偏移量
END_VAR

VAR_OUTPUT
    ScaledValue   : REAL;        // 缩放后的工程值
    IsValid       : BOOL;        // 值是否有效
    OutOfRange    : BOOL;        // 超范围标志
END_VAR

VAR
    MinRaw        : INT := 0;    // 最小原始值
    MaxRaw        : INT := 27648; // 最大原始值
    MinEng        : REAL := 0.0;  // 最小工程值
    MaxEng        : REAL := 100.0; // 最大工程值
END_VAR

// 范围检查
IF RawValue >= MinRaw AND RawValue <= MaxRaw THEN
    IsValid := TRUE;
    OutOfRange := FALSE;
    
    // 线性转换
    ScaledValue := (INT_TO_REAL(RawValue - MinRaw) / 
                   INT_TO_REAL(MaxRaw - MinRaw)) * 
                   (MaxEng - MinEng) + MinEng;
    
    // 应用缩放和偏移
    ScaledValue := ScaledValue * ScalingFactor + Offset;
ELSE
    IsValid := FALSE;
    OutOfRange := TRUE;
    ScaledValue := 0.0;
END_IF

END_FUNCTION_BLOCK

//------------------------------------------------------------------------
// 5. 任务配置示例
//------------------------------------------------------------------------

// 主任务 - 周期性执行
// TASK MainTask(INTERVAL := T#10ms, PRIORITY := 1);

// 快速任务 - 高速控制
// TASK FastTask(INTERVAL := T#1ms, PRIORITY := 0);

// 慢速任务 - 数据记录
// TASK SlowTask(INTERVAL := T#100ms, PRIORITY := 2);

// 任务分配
// PROGRAM P1 WITH MainTask : MainProgram;
// PROGRAM P2 WITH FastTask : FastControlProgram;
// PROGRAM P3 WITH SlowTask : DataLoggingProgram;

//------------------------------------------------------------------------
// 6. 常用功能库
//------------------------------------------------------------------------

// 平均值滤波
FUNCTION FC_AverageFilter : REAL
VAR_INPUT
    InputValue    : REAL;
    FilterDepth   : INT := 5;
END_VAR

VAR_IN_OUT
    Buffer        : ARRAY[*] OF REAL;
    Index         : INT;
END_VAR

VAR
    Sum           : REAL;
    i             : INT;
END_VAR

// 更新缓冲区
Buffer[Index] := InputValue;
Index := Index + 1;
IF Index >= FilterDepth THEN
    Index := 0;
END_IF

// 计算平均值
Sum := 0.0;
FOR i := 0 TO FilterDepth-1 DO
    Sum := Sum + Buffer[i];
END_FOR

FC_AverageFilter := Sum / INT_TO_REAL(FilterDepth);

END_FUNCTION

//------------------------------------------------------------------------
// 7. 通讯功能示例
//------------------------------------------------------------------------

FUNCTION_BLOCK FB_ModbusCommunication
VAR_INPUT
    Enable        : BOOL;
    SlaveID       : BYTE;
    FunctionCode  : BYTE;
    StartAddress  : WORD;
    Quantity      : WORD;
END_VAR

VAR_OUTPUT
    Done          : BOOL;
    Error         : BOOL;
    DataBuffer    : ARRAY[0..255] OF WORD;
END_VAR

VAR
    ModbusFB      : MODBUS_MASTER;  // 假设的Modbus功能块
    State         : INT := 0;
    TimeoutTimer  : TON;
END_VAR

IF Enable THEN
    CASE State OF
        0:  // 空闲状态
            ModbusFB(REQ := TRUE);
            State := 1;
            TimeoutTimer(IN := TRUE, PT := T#1s);
        
        1:  // 等待响应
            IF ModbusFB.DONE THEN
                DataBuffer := ModbusFB.DATA;
                Done := TRUE;
                State := 2;
            ELSIF ModbusFB.ERROR THEN
                Error := TRUE;
                State := 2;
            END_IF
            
            // 超时检查
            IF TimeoutTimer.Q THEN
                Error := TRUE;
                State := 2;
            END_IF
        
        2:  // 完成状态
            IF NOT Enable THEN
                State := 0;
                Done := FALSE;
                Error := FALSE;
                TimeoutTimer(IN := FALSE);
            END_IF
    END_CASE
ELSE
    State := 0;
    Done := FALSE;
    Error := FALSE;
END_IF

END_FUNCTION_BLOCK

//------------------------------------------------------------------------
// 8. 配方管理示例
//------------------------------------------------------------------------

FUNCTION_BLOCK FB_RecipeManager
VAR_INPUT
    LoadRecipe    : BOOL;
    SaveRecipe    : BOOL;
    RecipeNumber  : INT;
END_VAR

VAR_OUTPUT
    Done          : BOOL;
    Error         : BOOL;
END_VAR

VAR
    // 配方数据结构
    TYPE Recipe :
    STRUCT
        RecipeID    : INT;
        Temperature : REAL;
        Pressure    : REAL;
        Speed       : REAL;
        Time        : TIME;
    END_STRUCT;
    
    // 配方数组
    Recipes       : ARRAY[1..10] OF Recipe;
    
    // 当前配方
    CurrentRecipe : Recipe;
    
    State         : INT := 0;
END_VAR

CASE State OF
    0:  // 等待命令
        IF LoadRecipe THEN
            IF RecipeNumber >= 1 AND RecipeNumber <= 10 THEN
                CurrentRecipe := Recipes[RecipeNumber];
                Done := TRUE;
                State := 1;
            ELSE
                Error := TRUE;
                State := 1;
            END_IF
        ELSIF SaveRecipe THEN
            IF RecipeNumber >= 1 AND RecipeNumber <= 10 THEN
                Recipes[RecipeNumber] := CurrentRecipe;
                Done := TRUE;
                State := 1;
            ELSE
                Error := TRUE;
                State := 1;
            END_IF
        END_IF
    
    1:  // 完成状态
        IF NOT LoadRecipe AND NOT SaveRecipe THEN
            State := 0;
            Done := FALSE;
            Error := FALSE;
        END_IF
END_CASE

END_FUNCTION_BLOCK

//------------------------------------------------------------------------
// 9. 全局变量定义
//------------------------------------------------------------------------

VAR_GLOBAL
    // 系统状态
    SystemPowerOn : BOOL := FALSE;
    SystemMode    : INT := 0;  // 0:手动, 1:自动, 2:维护
    
    // 报警管理
    AlarmActive   : BOOL;
    AlarmCode     : DINT;
    AlarmTime     : TIME;
    
    // 生产数据
    ProductionTarget : DINT := 1000;
    ProductionCount  : DINT;
    ProductionRate   : REAL;
    
    // 设备状态
    DeviceReady   : ARRAY[1..10] OF BOOL;
    DeviceFault   : ARRAY[1..10] OF BOOL;
END_VAR

//------------------------------------------------------------------------
// 10. 注释和文档示例
//------------------------------------------------------------------------

(*
 * 功能：主控制程序
 * 作者：控制系统工程师
 * 版本：V1.0
 * 日期：2024-01-01
 * 修改记录：
 *   2024-01-01 - 初始版本
 *   2024-02-01 - 添加PID控制
 *   2024-03-01 - 优化状态机
 *)

// 单行注释
(* 多行注释
   可以跨越多行 *)

//------------------------------------------------------------------------
// 结束
//------------------------------------------------------------------------