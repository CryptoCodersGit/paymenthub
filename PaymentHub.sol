
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    =====================================================
                CRYPTO CODERS
       SMART TREASURY & PAYROLL SYSTEM
    =====================================================

    هدف پروژه:
    ساخت یک سیستم مدیریت خزانه، تقسیم درآمد و پرداخت حقوق
    با استفاده از قرارداد هوشمند Solidity.

    امکانات:
    1. دریافت ETH و مدیریت خزانه
    2. تقسیم درآمد بین چهار بخش
    3. مدیریت کارکنان و حقوق ماهانه
    4. محاسبه حقوق بر اساس زمان سپری‌شده
    5. پرداخت سهم شرکا
    6. برداشت هزینه‌های عملیاتی و ذخیره
    7. توقف اضطراری قرارداد
    8. محافظت در برابر حمله Reentrancy

    نکته:
    این پروژه آموزشی است و برای استفاده با سرمایه واقعی
    به تست جامع، بررسی امنیتی و ممیزی تخصصی نیاز دارد.
*/

contract PaymentHub {

    // =====================================================
    // 1. CONSTANTS
    // =====================================================

    // مبنای محاسبه درصدها:
    // 10000 یعنی 100 درصد
    // 4000 یعنی 40 درصد
    uint256 public constant BPS = 10000;

    // هر ماه را برای محاسبه حقوق، 30 روز در نظر می‌گیریم.
    uint256 public constant MONTH_DURATION = 30 days;

    // حداکثر تعداد شرکای ثبت‌شده
    uint256 public constant MAX_PARTNERS = 20;


    // =====================================================
    // 2. OWNER AND CONTRACT STATUS
    // =====================================================

    // مالک قرارداد
    address public owner;

    // وضعیت توقف قرارداد
    bool public paused;


    // =====================================================
    // 3. REVENUE ALLOCATION
    // =====================================================

    /*
        درصد پیش‌فرض تقسیم درآمد:

        40 درصد برای حقوق کارکنان
        30 درصد برای شرکا
        20 درصد برای هزینه‌های عملیاتی
        10 درصد برای ذخیره خزانه
    */

    uint256 public payrollPercent = 4000;
    uint256 public partnersPercent = 3000;
    uint256 public operationsPercent = 2000;
    uint256 public reservePercent = 1000;


    // =====================================================
    // 4. TREASURY BALANCES
    // =====================================================

    // درآمدی که هنوز تقسیم نشده است
    uint256 public unallocatedRevenue;

    // موجودی اختصاص‌یافته به حقوق کارکنان
    uint256 public payrollPool;

    // مجموع بدهی قرارداد به شرکا
    uint256 public totalPartnerLiability;

    // موجودی قابل برداشت برای هزینه‌های عملیاتی
    uint256 public operationsBalance;

    // موجودی ذخیره خزانه
    uint256 public reserveBalance;


    // =====================================================
    // 5. EMPLOYEE DATA
    // =====================================================

    /*
        اطلاعات هر کارمند:

        exists:
            آیا کارمند ثبت شده است؟

        active:
            آیا کارمند فعال است؟

        monthlySalary:
            حقوق ماهانه بر حسب Wei

        lastAccrualTime:
            آخرین زمان محاسبه حقوق

        accruedSalary:
            حقوق محاسبه‌شده و پرداخت‌ نشده

        accrualRemainder:
            باقی‌مانده محاسبات قبلی برای جلوگیری از
            از دست رفتن دقت در محاسبه حقوق
    */

    struct Employee {
        bool exists;
        bool active;
        uint256 monthlySalary;
        uint256 lastAccrualTime;
        uint256 accruedSalary;
        uint256 accrualRemainder;
    }

    // اطلاعات کارکنان بر اساس آدرس آن‌ها ذخیره می‌شود.
    mapping(address => Employee) private employees;


    // =====================================================
    // 6. PARTNER DATA
    // =====================================================

    // درصد سهم هر شریک
    mapping(address => uint256) public partnerWeight;

    // مبلغ قابل برداشت هر شریک
    mapping(address => uint256) public partnerClaimable;

    // فهرست آدرس شرکا
    address[] public partners;

    // مشخص می‌کند آدرس قبلاً به فهرست اضافه شده است یا خیر
    mapping(address => bool) public knownPartner;

    // مجموع درصد سهم شرکا
    uint256 public totalPartnerWeight;


    // =====================================================
    // 7. REENTRANCY PROTECTION
    // =====================================================

    /*
        این متغیر برای جلوگیری از حمله Reentrancy است.

        اگر looked برابر true باشد،
        اجرای مجدد توابع محافظت‌شده ممنوع می‌شود.
    */

    bool private looked;


    // =====================================================
    // 8. EVENTS
    // =====================================================

    event OwnershipTransferred(
        address indexed oldOwner,
        address indexed newOwner
    );

    event Deposited(
        address indexed sender,
        uint256 amount
    );

    event RevenueDistributed(uint256 totalAmount);

    event AllocationUpdated(
        uint256 payroll,
        uint256 partners,
        uint256 operations,
        uint256 reserve
    );

    event PartnerWeightUpdated(
        address indexed partner,
        uint256 newWeight
    );

    event PartnerPaymentClaimed(
        address indexed partner,
        uint256 amount
    );

    event EmployeeAdded(
        address indexed employee,
        uint256 monthlySalary
    );

    event EmployeeSalaryUpdated(
        address indexed employee,
        uint256 newSalary
    );

    event EmployeeDeactivated(
        address indexed employee
    );

    event SalaryClaimed(
        address indexed employee,
        uint256 amount
    );

    event OperationsWithdrawn(
        address indexed owner,
        uint256 amount
    );

    event ReserveWithdrawn(
        address indexed owner,
        uint256 amount
    );

    event Paused();
    event Unpaused();


    // =====================================================
    // 9. MODIFIERS
    // =====================================================

    // فقط مالک قرارداد اجازه اجرای تابع را دارد.
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // وقتی قرارداد متوقف است، اجرای تابع مجاز نیست.
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    /*
        محافظت در برابر Reentrancy:

        ابتدا بررسی می‌کنیم تابع در حال اجرا نباشد.
        سپس قفل را فعال می‌کنیم.
        در پایان اجرای تابع، قفل آزاد می‌شود.
    */

    modifier nonReentrant() {
        require(!looked, "Reentrancy detected");

        looked = true;

        _;

        looked = false;
    }


    // =====================================================
    // 10. CONSTRUCTOR
    // =====================================================

    constructor() {

        // شخصی که قرارداد را Deploy می‌کند، مالک اولیه است.
        owner = msg.sender;

        emit OwnershipTransferred(
            address(0),
            msg.sender
        );
    }


    // =====================================================
    // 11. DEPOSIT ETH
    // =====================================================

    /*
        واریز ETH به خزانه.

        هر کسی می‌تواند به این تابع ETH ارسال کند.
        مبلغ ابتدا وارد درآمد تقسیم‌نشده می‌شود.
    */

    function deposit()
        external
        payable
        whenNotPaused
    {
        _deposit();
    }


    /*
        این تابع زمانی اجرا می‌شود که کاربر
        مستقیماً ETH را به آدرس قرارداد ارسال کند.
    */

    receive()
        external
        payable
    {
        require(!paused, "Contract is paused");

        _deposit();
    }


    // منطق مشترک دریافت ETH
    function _deposit() internal {

        // واریز صفر مجاز نیست.
        require(msg.value > 0, "Amount must be greater than zero");

        // اضافه کردن مبلغ به درآمد تقسیم‌نشده
        unallocatedRevenue += msg.value;

        emit Deposited(msg.sender, msg.value);
    }


    // =====================================================
    // 12. UPDATE REVENUE ALLOCATION
    // =====================================================

    /*
        تغییر درصد تقسیم درآمد توسط مالک.

        مجموع چهار درصد باید دقیقاً 100 درصد باشد.
    */

    function setAllocations(
        uint256 _payroll,
        uint256 _partners,
        uint256 _operations,
        uint256 _reserve
    )
        external
        onlyOwner
        whenNotPaused
    {
        // مجموع درصدها باید برابر 10000 باشد.
        require(
            _payroll + _partners + _operations + _reserve == BPS,
            "Total allocation must be 100%"
        );

        // ثبت درصدهای جدید
        payrollPercent = _payroll;
        partnersPercent = _partners;
        operationsPercent = _operations;
        reservePercent = _reserve;

        emit AllocationUpdated(
            _payroll,
            _partners,
            _operations,
            _reserve
        );
    }


    // =====================================================
    // 13. PARTNER MANAGEMENT
    // =====================================================

    /*
        ثبت یا تغییر سهم یک شریک.

        مثال:
        6000 یعنی 60 درصد
        4000 یعنی 40 درصد

        مجموع سهم شرکا نباید بیشتر از 100 درصد شود.
    */

    function setPartnerWeight(
        address _partner,
        uint256 _weight
    )
        external
        onlyOwner
        whenNotPaused
    {
        // آدرس صفر مجاز نیست.
        require(_partner != address(0), "Invalid partner address");

        // سهم یک شریک نمی‌تواند بیشتر از 100 درصد باشد.
        require(_weight <= BPS, "Invalid weight");

        // سهم قبلی شریک
        uint256 oldWeight = partnerWeight[_partner];

        /*
            اگر شریک جدید است و سهم مثبت دارد،
            او را به فهرست شرکا اضافه می‌کنیم.
        */

        if (!knownPartner[_partner] && _weight > 0) {

            require(
                partners.length < MAX_PARTNERS,
                "Partner limit reached"
            );

            knownPartner[_partner] = true;

            partners.push(_partner);
        }

        // محاسبه مجموع جدید سهم شرکا
        uint256 newTotalWeight =
            totalPartnerWeight - oldWeight + _weight;

        // مجموع سهم‌ها نباید از 100 درصد بیشتر شود.
        require(
            newTotalWeight <= BPS,
            "Total partner weight too high"
        );

        // ذخیره سهم جدید
        partnerWeight[_partner] = _weight;

        totalPartnerWeight = newTotalWeight;

        emit PartnerWeightUpdated(
            _partner,
            _weight
        );
    }


    // =====================================================
    // 14. DISTRIBUTE REVENUE
    // =====================================================

    /*
        تقسیم درآمد بین چهار بخش:

        1. حقوق کارکنان
        2. شرکا
        3. هزینه‌های عملیاتی
        4. ذخیره خزانه

        فقط مالک می‌تواند این تابع را اجرا کند.

        درصدهای جدید فقط روی درآمدهای تقسیم‌نشده اعمال می‌شوند.
    */

    function distributeRevenue()
        external
        onlyOwner
        whenNotPaused
    {
        // کل درآمد تقسیم‌نشده
        uint256 totalAmount = unallocatedRevenue;

        require(
            totalAmount > 0,
            "No revenue to distribute"
        );

        /*
            اگر قرار است سهمی به شرکا اختصاص پیدا کند،
            مجموع سهم‌های ثبت‌شده باید دقیقاً 100 درصد باشد.
        */

        if (partnersPercent > 0) {

            require(
                totalPartnerWeight == BPS,
                "Partner weights must equal 100%"
            );
        }

        /*
            درآمد تقسیم‌نشده را صفر می‌کنیم.
            به این ترتیب همین مبلغ دوباره تقسیم نمی‌شود.
        */

        unallocatedRevenue = 0;

        // محاسبه سهم حقوق کارکنان
        uint256 payrollAmount =
            (totalAmount * payrollPercent) / BPS;

        // محاسبه سهم هزینه‌های عملیاتی
        uint256 operationsAmount =
            (totalAmount * operationsPercent) / BPS;

        // محاسبه سهم اختصاص‌یافته به شرکا
        uint256 partnerAmount =
            (totalAmount * partnersPercent) / BPS;

        // اضافه کردن سهم حقوق به مخزن حقوق
        payrollPool += payrollAmount;

        // اضافه کردن سهم عملیات به موجودی عملیاتی
        operationsBalance += operationsAmount;

        /*
            تقسیم سهم شرکا:

            سهم هر شریک بر اساس وزن او محاسبه می‌شود.
        */

        uint256 distributedToPartners = 0;

        if (partnerAmount > 0) {

            // پیمایش فهرست شرکا
            for (uint256 i = 0; i < partners.length; i++) {

                address partner = partners[i];

                // محاسبه سهم این شریک
                uint256 share =
                    (partnerAmount * partnerWeight[partner]) / BPS;

                // اضافه کردن مبلغ به موجودی قابل برداشت شریک
                partnerClaimable[partner] += share;

                // ثبت مجموع سهم‌های تقسیم‌شده
                distributedToPartners += share;
            }

            // ثبت مجموع بدهی قرارداد به شرکا
            totalPartnerLiability += distributedToPartners;
        }

        /*
            مبلغ باقی‌مانده به ذخیره اضافه می‌شود.

            این مبلغ شامل درصد اصلی ذخیره و همچنین
            باقی‌مانده کوچک ناشی از گرد کردن سهم شرکاست.
        */

        uint256 remainingAmount =
            totalAmount
            - payrollAmount
            - operationsAmount
            - distributedToPartners;

        reserveBalance += remainingAmount;

        emit RevenueDistributed(totalAmount);
    }


    // =====================================================
    // 15. ADD EMPLOYEE
    // =====================================================

    /*
        ثبت کارمند جدید.

        حقوق ماهانه بر حسب Wei وارد می‌شود.

        مثال:
        1 ETH = 1000000000000000000 Wei
    */

    function addEmployee(
        address _employee,
        uint256 _monthlySalary
    )
        external
        onlyOwner
        whenNotPaused
    {
        // آدرس صفر مجاز نیست.
        require(
            _employee != address(0),
            "Invalid employee address"
        );

        // کارمند نباید قبلاً ثبت شده باشد.
        require(
            !employees[_employee].exists,
            "Employee already exists"
        );

        // حقوق ماهانه باید بیشتر از صفر باشد.
        require(
            _monthlySalary > 0,
            "Salary must be greater than zero"
        );

        // ذخیره اطلاعات کارمند
        employees[_employee] = Employee({
            exists: true,
            active: true,
            monthlySalary: _monthlySalary,
            lastAccrualTime: block.timestamp,
            accruedSalary: 0,
            accrualRemainder: 0
        });

        emit EmployeeAdded(
            _employee,
            _monthlySalary
        );
    }


    // =====================================================
    // 16. UPDATE EMPLOYEE SALARY
    // =====================================================

    /*
        تغییر حقوق ماهانه کارمند.

        ابتدا حقوق قبلی تا همین لحظه محاسبه می‌شود.
        سپس حقوق جدید ثبت می‌شود.

        بنابراین حقوق جدید روی زمان گذشته تأثیر نمی‌گذارد.
    */

    function updateEmployeeSalary(
        address _employee,
        uint256 _newSalary
    )
        external
        onlyOwner
        whenNotPaused
    {
        Employee storage employee = employees[_employee];

        require(
            employee.exists,
            "Employee does not exist"
        );

        require(
            employee.active,
            "Employee is not active"
        );

        require(
            _newSalary > 0,
            "Salary must be greater than zero"
        );

        // محاسبه حقوق با نرخ قبلی
        _accrueEmployee(employee);

        // ثبت حقوق جدید
        employee.monthlySalary = _newSalary;

        emit EmployeeSalaryUpdated(
            _employee,
            _newSalary
        );
    }


    // =====================================================
    // 17. DEACTIVATE EMPLOYEE
    // =====================================================

    /*
        غیرفعال کردن کارمند.

        بعد از غیرفعال شدن:
        - حقوق جدیدی برای او محاسبه نمی‌شود.
        - حقوق قبلی او همچنان قابل برداشت است.
    */

    function deactivateEmployee(address _employee)
        external
        onlyOwner
        whenNotPaused
    {
        Employee storage employee = employees[_employee];

        require(
            employee.exists,
            "Employee does not exist"
        );

        require(
            employee.active,
            "Employee already inactive"
        );

        // محاسبه آخرین حقوق کارمند
        _accrueEmployee(employee);

        // غیرفعال کردن کارمند
        employee.active = false;

        emit EmployeeDeactivated(_employee);
    }


    // =====================================================
    // 18. ACCRUE EMPLOYEE SALARY
    // =====================================================

    /*
        محاسبه حقوق کارمند بر اساس زمان سپری‌شده.

        فرمول:

        حقوق جدید =
        حقوق ماهانه × زمان سپری‌شده / مدت یک ماه

        این تابع ETH انتقال نمی‌دهد.
        فقط طلب کارمند را در اطلاعات او ثبت می‌کند.
    */

    function _accrueEmployee(
        Employee storage employee
    )
        internal
    {
        // کارمند غیرفعال حقوق جدیدی به دست نمی‌آورد.
        if (!employee.active) {
            return;
        }

        // مدت زمان سپری‌شده از آخرین محاسبه
        uint256 elapsed =
            block.timestamp - employee.lastAccrualTime;

        // اگر زمانی سپری نشده باشد، محاسبه لازم نیست.
        if (elapsed == 0) {
            return;
        }

        /*
            محاسبه صورت کسر:

            زمان سپری‌شده × حقوق ماهانه

            باقی‌مانده محاسبه قبلی نیز اضافه می‌شود
            تا دقت محاسبه در دفعات بعد حفظ شود.
        */

        uint256 numerator =
            (elapsed * employee.monthlySalary)
            + employee.accrualRemainder;

        // حقوق جدید قابل ثبت
        uint256 earned =
            numerator / MONTH_DURATION;

        // ذخیره باقی‌مانده تقسیم
        employee.accrualRemainder =
            numerator % MONTH_DURATION;

        // اضافه کردن حقوق جدید به طلب کارمند
        employee.accruedSalary += earned;

        // به‌روزرسانی زمان آخرین محاسبه
        employee.lastAccrualTime = block.timestamp;
    }


    // =====================================================
    // 19. CALCULATE EMPLOYEE SALARY
    // =====================================================

    /*
        مشاهده حقوقی که کارمند تا همین لحظه به دست آورده است.

        این تابع فقط اطلاعات را نمایش می‌دهد
        و وضعیت قرارداد را تغییر نمی‌دهد.
    */

    function calculateSalary(address _employee)
        public
        view
        returns (uint256)
    {
        Employee storage employee = employees[_employee];

        require(
            employee.exists,
            "Employee does not exist"
        );

        // حقوقی که قبلاً ثبت شده است
        uint256 currentSalary = employee.accruedSalary;

        // اگر کارمند فعال باشد، حقوق زمان جدید را محاسبه می‌کنیم.
        if (employee.active) {

            uint256 elapsed =
                block.timestamp - employee.lastAccrualTime;

            uint256 numerator =
                (elapsed * employee.monthlySalary)
                + employee.accrualRemainder;

            uint256 earned =
                numerator / MONTH_DURATION;

            currentSalary += earned;
        }

        return currentSalary;
    }


    // =====================================================
    // 20. CLAIM EMPLOYEE SALARY
    // =====================================================

    /*
        کارمند با اجرای این تابع حقوق خود را برداشت می‌کند.

        اگر موجودی مخزن حقوق کافی نباشد،
        فقط موجودی فعلی پرداخت می‌شود.

        باقی‌مانده طلب کارمند حفظ می‌شود.
    */

    function claimSalary()
        external
        whenNotPaused
        nonReentrant
    {
        Employee storage employee = employees[msg.sender];

        require(
            employee.exists,
            "Employee does not exist"
        );

        // محاسبه حقوق تا زمان فعلی
        _accrueEmployee(employee);

        // کل حقوق پرداخت‌نشده کارمند
        uint256 owed = employee.accruedSalary;

        require(
            owed > 0,
            "No salary available"
        );

        // مبلغ پرداختی ابتدا برابر کل طلب است.
        uint256 amount = owed;

        /*
            اگر موجودی مخزن حقوق کمتر از طلب باشد،
            مبلغ پرداختی را به اندازه موجودی مخزن محدود می‌کنیم.
        */

        if (amount > payrollPool) {
            amount = payrollPool;
        }

        require(
            amount > 0,
            "Payroll pool is empty"
        );

        /*
            ابتدا حسابداری را به‌روزرسانی می‌کنیم.
            این ترتیب برای محافظت در برابر Reentrancy مهم است.
        */

        employee.accruedSalary -= amount;

        payrollPool -= amount;

        // انتقال ETH به کارمند
        (bool success, ) =
            payable(msg.sender).call{value: amount}("");

        require(
            success,
            "Salary transfer failed"
        );

        emit SalaryClaimed(
            msg.sender,
            amount
        );
    }


    // =====================================================
    // 21. CLAIM PARTNER SHARE
    // =====================================================

    /*
        هر شریک می‌تواند سهم خودش را برداشت کند.

        این روش Pull Payment نام دارد.
        یعنی قرارداد به صورت خودکار برای شرکا پول نمی‌فرستد.
        هر شریک خودش برداشت را انجام می‌دهد.
    */

    function claimPartnerShare()
        external
        whenNotPaused
        nonReentrant
    {
        // موجودی قابل برداشت شریک
        uint256 amount = partnerClaimable[msg.sender];

        require(
            amount > 0,
            "No partner payment available"
        );

        // ابتدا موجودی قابل برداشت را صفر می‌کنیم.
        partnerClaimable[msg.sender] = 0;

        // کاهش بدهی کلی قرارداد به شرکا
        totalPartnerLiability -= amount;

        // انتقال ETH به شریک
        (bool success, ) =
            payable(msg.sender).call{value: amount}("");

        require(
            success,
            "Partner transfer failed"
        );

        emit PartnerPaymentClaimed(
            msg.sender,
            amount
        );
    }


    // =====================================================
    // 22. WITHDRAW OPERATIONS BALANCE
    // =====================================================

    /*
        مالک می‌تواند از موجودی هزینه‌های عملیاتی برداشت کند.

        این موجودی از حقوق کارکنان و سهم شرکا جداست.
    */

    function withdrawOperatingFunds(uint256 _amount)
        external
        onlyOwner
        whenNotPaused
        nonReentrant
    {
        require(
            _amount > 0,
            "Amount must be greater than zero"
        );

        require(
            _amount <= operationsBalance,
            "Insufficient operations balance"
        );

        // ذخیره آدرس مالک پیش از انتقال
        address payable recipient = payable(owner);

        // کاهش موجودی عملیاتی
        operationsBalance -= _amount;

        // انتقال ETH به مالک
        (bool success, ) =
            recipient.call{value: _amount}("");

        require(
            success,
            "Operations transfer failed"
        );

        emit OperationsWithdrawn(
            recipient,
            _amount
        );
    }


    // =====================================================
    // 23. WITHDRAW RESERVE BALANCE
    // =====================================================

    /*
        برداشت از ذخیره خزانه فقط توسط مالک انجام می‌شود.

        ذخیره شامل درصد اختصاص‌یافته به Reserve
        و باقی‌مانده گرد کردن محاسبات تقسیم درآمد است.
    */

    function withdrawReserveFunds(uint256 _amount)
        external
        onlyOwner
        whenNotPaused
        nonReentrant
    {
        require(
            _amount > 0,
            "Amount must be greater than zero"
        );

        require(
            _amount <= reserveBalance,
            "Insufficient reserve balance"
        );

        // ذخیره آدرس مالک پیش از انتقال
        address payable recipient = payable(owner);

        // کاهش موجودی ذخیره
        reserveBalance -= _amount;

        // انتقال ETH به مالک
        (bool success, ) =
            recipient.call{value: _amount}("");

        require(
            success,
            "Reserve transfer failed"
        );

        emit ReserveWithdrawn(
            recipient,
            _amount
        );
    }


    // =====================================================
    // 24. GET EMPLOYEE INFORMATION
    // =====================================================

    /*
        مشاهده اطلاعات کارمند.

        اگر آدرس ثبت نشده باشد،
        اطلاعات صفر برگردانده می‌شود.

        recordedSalary:
            حقوقی که قبلاً ثبت شده است.

        totalEarnedSalary:
            کل حقوق به دست آمده تا زمان فعلی.
    */

    function getEmployeeInfo(address _employee)
        external
        view
        returns (
            bool exists,
            bool active,
            uint256 monthlySalary,
            uint256 recordedSalary,
            uint256 totalEarnedSalary
        )
    {
        Employee storage employee = employees[_employee];

        // اگر کارمند ثبت نشده باشد، اطلاعات خالی برمی‌گردد.
        if (!employee.exists) {
            return (
                false,
                false,
                0,
                0,
                0
            );
        }

        return (
            employee.exists,
            employee.active,
            employee.monthlySalary,
            employee.accruedSalary,
            calculateSalary(_employee)
        );
    }


    // =====================================================
    // 25. GET PARTNER INFORMATION
    // =====================================================

    // مشاهده درصد سهم و مبلغ قابل برداشت یک شریک

    function getPartnerInfo(address _partner)
        external
        view
        returns (
            uint256 weight,
            uint256 claimable
        )
    {
        return (
            partnerWeight[_partner],
            partnerClaimable[_partner]
        );
    }


    // =====================================================
    // 26. GET ALL PARTNERS
    // =====================================================

    // دریافت فهرست تمام آدرس‌های ثبت‌شده به عنوان شریک

    function getPartners()
        external
        view
        returns (address[] memory)
    {
        return partners;
    }


    // =====================================================
    // 27. GET TREASURY INFORMATION
    // =====================================================

    /*
        مشاهده وضعیت کلی خزانه:

        actualBalance:
            موجودی واقعی ETH در قرارداد

        unallocated:
            درآمد تقسیم‌نشده

        payroll:
            موجودی اختصاص‌یافته به حقوق

        partnerLiability:
            مجموع بدهی قرارداد به شرکا

        operations:
            موجودی هزینه‌های عملیاتی

        reserve:
            موجودی ذخیره

        unaccounted:
            ETH اضافی که در حسابداری ثبت نشده است.
    */

    function getTreasuryInfo()
        external
        view
        returns (
            uint256 actualBalance,
            uint256 unallocated,
            uint256 payroll,
            uint256 partnerLiability,
            uint256 operations,
            uint256 reserve,
            uint256 unaccounted
        )
    {
        // موجودی واقعی قرارداد
        actualBalance = address(this).balance;

        // خواندن موجودی هر بخش
        unallocated = unallocatedRevenue;
        payroll = payrollPool;
        partnerLiability = totalPartnerLiability;
        operations = operationsBalance;
        reserve = reserveBalance;

        // محاسبه مجموع موجودی‌های ثبت‌شده
        uint256 accountedBalance =
            unallocated
            + payroll
            + partnerLiability
            + operations
            + reserve;

        /*
            اگر موجودی واقعی بیشتر از موجودی ثبت‌شده باشد،
            اختلاف به عنوان ETH ثبت‌نشده نمایش داده می‌شود.

            برای مثال ممکن است ETH به روش اجباری وارد قرارداد شود.
        */

        if (actualBalance > accountedBalance) {
            unaccounted = actualBalance - accountedBalance;
        }
    }


    // =====================================================
    // 28. PAUSE AND UNPAUSE
    // =====================================================

    /*
        توقف اضطراری عملیات قرارداد.

        مالک می‌تواند در صورت مشاهده مشکل،
        عملیات اصلی را متوقف کند.
    */

    function pause()
        external
        onlyOwner
    {
        require(
            !paused,
            "Already paused"
        );

        paused = true;

        emit Paused();
    }


    // فعال کردن دوباره عملیات قرارداد

    function unpause()
        external
        onlyOwner
    {
        require(
            paused,
            "Not paused"
        );

        paused = false;

        emit Unpaused();
    }


    // =====================================================
    // 29. TRANSFER OWNERSHIP
    // =====================================================

    /*
        انتقال مالکیت قرارداد به آدرس جدید.

        این تابع حتی در زمان Pause هم قابل اجراست
        تا امکان تغییر مالک در شرایط اضطراری وجود داشته باشد.
    */

    function transferOwnership(address _newOwner)
        external
        onlyOwner
    {
        require(
            _newOwner != address(0),
            "Invalid new owner"
        );

        // ذخیره مالک قبلی
        address oldOwner = owner;

        // ثبت مالک جدید
        owner = _newOwner;

        emit OwnershipTransferred(
            oldOwner,
            _newOwner
        );
    }

}
