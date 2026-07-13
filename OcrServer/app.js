let pipeline = [];
let accountRules = JSON.parse(localStorage.getItem('accountRules')) || [
    { keyword: 'OMV', account: '6022' },
    { keyword: 'PETROM', account: '6022' },
    { keyword: 'MOL ', account: '6022' },
    { keyword: 'LUKOIL', account: '6022' },
    { keyword: 'ENEL', account: '605' },
    { keyword: 'E.ON', account: '605' },
    { keyword: 'ENGIE', account: '605' },
    { keyword: 'CAFEA', account: '623' },
    { keyword: 'RESTAURANT', account: '623' },
    { keyword: 'FAN COURIER', account: '624' }
];

function saveRules() {
    localStorage.setItem('accountRules', JSON.stringify(accountRules));
    renderRules();
}

function renderRules() {
    const tbody = document.getElementById('rules-body');
    if (!tbody) return;
    tbody.innerHTML = '';
    accountRules.forEach((rule, idx) => {
        tbody.innerHTML += `
            <tr>
                <td>${rule.keyword}</td>
                <td>${rule.account}</td>
                <td><button class="btn-text" style="color: var(--danger)" onclick="deleteRule(${idx})">Șterge</button></td>
            </tr>
        `;
    });
}

window.deleteRule = function(idx) {
    accountRules.splice(idx, 1);
    saveRules();
}

window.addAccountRule = function() {
    const kw = document.getElementById('rule-keyword').value.toUpperCase().trim();
    const acc = document.getElementById('rule-account').value.trim();
    if (kw && acc) {
        accountRules.push({ keyword: kw, account: acc });
        document.getElementById('rule-keyword').value = '';
        document.getElementById('rule-account').value = '';
        saveRules();
    }
}

// Tabs
window.switchTab = function(tabId) {
    document.querySelectorAll('.tab-content').forEach(el => el.classList.add('hidden'));
    document.getElementById(`tab-${tabId}`).classList.remove('hidden');
    document.querySelectorAll('nav a').forEach(el => el.classList.remove('active'));
    event.currentTarget.classList.add('active');
}

// Drag & Drop
const dropZone = document.getElementById('drop-zone');
const fileInput = document.getElementById('file-input');

['dragenter', 'dragover', 'dragleave', 'drop'].forEach(eventName => {
    dropZone.addEventListener(eventName, preventDefaults, false);
});
function preventDefaults(e) { e.preventDefault(); e.stopPropagation(); }
['dragenter', 'dragover'].forEach(eventName => { dropZone.addEventListener(eventName, () => dropZone.classList.add('dragover'), false); });
['dragleave', 'drop'].forEach(eventName => { dropZone.addEventListener(eventName, () => dropZone.classList.remove('dragover'), false); });

dropZone.addEventListener('drop', e => handleFiles(e.dataTransfer.files));
dropZone.addEventListener('click', () => fileInput.click());
fileInput.addEventListener('change', e => handleFiles(e.target.files));

function handleFiles(files) {
    Array.from(files).forEach(file => {
        if (!file.type.startsWith('image/') && file.type !== 'application/pdf') return;
        const id = Date.now() + Math.random().toString(36).substr(2, 9);
        pipeline.push({ id, file, status: 'pending', name: file.name, data: null, url: URL.createObjectURL(file) });
    });
    
    // Stergem selectia anterioara pentru a putea uploada acelasi fisier din nou fara refresh
    fileInput.value = '';
    
    renderPipeline();
    processNext();
}

function suggestAccount(companyName, fileType, serverSuggestion = '') {
    if (serverSuggestion && serverSuggestion.trim()) return serverSuggestion;
    if (fileType === 'Chitanță de mână') return '5311';
    if (fileType === 'Chitanță POS') return '5125';
    const text = (companyName || '').toUpperCase();
    for (let rule of accountRules) {
        if (text.includes(rule.keyword)) return rule.account;
    }
    // Simple fallback if no rule matches
    return fileType === 'Bon Fiscal' ? '602' : '371';
}

function renderPipeline() {
    const tbody = document.getElementById('pipeline-body');
    if (pipeline.length === 0) {
        tbody.innerHTML = `<tr id="empty-row"><td colspan="13" style="text-align: center; color: var(--text-muted); padding: 40px;">Niciun document în așteptare. Încarcă fișiere pentru a începe.</td></tr>`;
        return;
    }
    
    // Dynamic renaming of total header
    const hasChitante = pipeline.some(x => x.data && (x.data.documentType === 'Chitanță de mână' || x.data.documentType === 'Chitanță POS'));
    const totalHeader = document.getElementById('header-total');
    if (totalHeader) {
        totalHeader.innerText = hasChitante ? 'Total / Sumă Plătită' : 'Total (cu TVA)';
    }
    
    tbody.innerHTML = '';
    pipeline.forEach((item, index) => {
        let statusHtml = '';
        if (item.status === 'pending') statusHtml = `<span class="status-badge status-pending"><i class="ph ph-hourglass"></i> Așteptare</span>`;
        if (item.status === 'processing') statusHtml = `<span class="status-badge status-processing"><i class="ph ph-spinner ph-spin"></i> Procesare</span>`;
        if (item.status === 'done') {
            const hasWarnings = item.data.globalRequiresManualVerification;
            statusHtml = hasWarnings 
                ? `<span class="status-badge status-warn" title="Necesită Atenție"><i class="ph ph-warning"></i> Atenție</span>` 
                : `<span class="status-badge status-ok"><i class="ph ph-check-circle"></i> Validat</span>`;
        }
        if (item.status === 'error') statusHtml = `<span class="status-badge status-err"><i class="ph ph-x-circle"></i> Eroare</span>`;

        const d = item.data || {};
        const isChitanta = d.documentType === 'Chitanță de mână' || d.documentType === 'Chitanță POS';
        
        // Editable fields if done
        const typeHtml = item.status === 'done' ? `<input class="inline-input" value="${d.documentType || ''}" onchange="updateItem('${item.id}', 'documentType', this.value)">` : '-';
        const serieHtml = item.status === 'done' ? `<input class="inline-input" style="width: 80px" value="${d.documentSeries || ''}" onchange="updateItem('${item.id}', 'documentSeries', this.value)">` : '-';
        const numarHtml = item.status === 'done' ? `<input class="inline-input" style="width: 100px" value="${d.documentNumber || ''}" onchange="updateItem('${item.id}', 'documentNumber', this.value)">` : '-';
        const dataHtml = item.status === 'done' ? `<input class="inline-input" style="width: 110px" value="${d.documentDate || ''}" onchange="updateItem('${item.id}', 'documentDate', this.value)">` : '-';
        const cuiHtml = item.status === 'done' ? `<input class="inline-input" value="${d.cui || ''}" onchange="updateItem('${item.id}', 'cui', this.value)" title="${d.companyName || ''}">` : '-';
        const companyHtml = item.status === 'done' ? `<input class="inline-input" style="width: 150px" value="${d.companyName || ''}" onchange="updateItem('${item.id}', 'companyName', this.value)">` : '-';
        
        const baseHtml = item.status === 'done' ? (isChitanta ? '<span style="color:var(--text-muted)">-</span>' : `<input class="inline-input" style="width: 80px" value="${d.baseAmount !== undefined ? d.baseAmount : ''}" onchange="updateItem('${item.id}', 'baseAmount', this.value)">`) : '-';
        const totalHtml = item.status === 'done' ? `<input class="inline-input" style="width: 80px" value="${d.totalAmount || ''}" onchange="updateItem('${item.id}', 'totalAmount', this.value)">` : '-';
        const vatHtml = item.status === 'done' ? (isChitanta ? '<span style="color:var(--text-muted)">-</span>' : `<input class="inline-input" style="width: 80px" value="${d.vatAmount !== undefined ? d.vatAmount : ''}" onchange="updateItem('${item.id}', 'vatAmount', this.value)">`) : '-';
        const vatPctHtml = item.status === 'done' ? (isChitanta ? '<span style="color:var(--text-muted)">-</span>' : `<input class="inline-input" style="width: 60px" value="${d.vatPercentages || ''}" onchange="updateItem('${item.id}', 'vatPercentages', this.value)">`) : '-';
        const accHtml = item.status === 'done' ? `<input class="inline-input" value="${d.suggestedAccount || ''}" onchange="updateItem('${item.id}', 'suggestedAccount', this.value)">` : '-';

        tbody.innerHTML += `
            <tr>
                <td>
                    <span class="status-badge ${item.status === 'done' ? 'status-valid' : (item.status === 'error' ? 'status-error' : 'status-pending')}">
                        ${item.status === 'done' ? '<i class="ph ph-check-circle"></i> VALIDAT' : (item.status === 'error' ? '<i class="ph ph-warning"></i> EROARE' : '<i class="ph ph-spinner ph-spin"></i> PROCESARE')}
                    </span>
                </td>
                <td><a href="#" onclick="viewImage('${item.id}')" style="color:var(--primary);text-decoration:none;font-weight:500;">${item.name || item.file.name}</a></td>
                <td>${item.status === 'done' ? d.documentType || 'Necunoscut' : '-'}</td>
                <td>${serieHtml}</td>
                <td>${numarHtml}</td>
                <td>${dataHtml}</td>
                <td>${cuiHtml}</td>
                <td>${companyHtml}</td>
                <td>${baseHtml}</td>
                <td>${vatHtml}</td>
                <td>${vatPctHtml}</td>
                <td>${totalHtml}</td>
                <td>${accHtml}</td>
                <td><button class="btn-text" onclick="removePipelineItem('${item.id}')" style="color:var(--danger)">Șterge</button></td>
            </tr>
        `;
    });
}

window.updateItem = function(id, field, value) {
    const item = pipeline.find(x => x.id === id);
    if (item && item.data) {
        item.data[field] = value;
    }
}

window.removePipelineItem = function(id) {
    pipeline = pipeline.filter(x => x.id !== id);
    renderPipeline();
}

window.viewImage = function(id) {
    const item = pipeline.find(x => x.id === id);
    if (item) {
        document.getElementById('modal-img').src = item.url;
        const warnDiv = document.getElementById('modal-warnings');
        warnDiv.innerHTML = '';
        if (item.data && item.data.fiscalWarnings && item.data.fiscalWarnings.length > 0) {
            warnDiv.innerHTML = `<strong>Alerte Fiscale:</strong><br>` + item.data.fiscalWarnings.join('<br>');
        }
        
        if (item.rawResponse) {
            if (typeof renderReceipts === 'function') renderReceipts(item.rawResponse);
            if (typeof renderChitante === 'function') renderChitante(item.rawResponse);
        }
        
        document.getElementById('image-modal').classList.remove('hidden');
    }
}

window.closeModal = function() {
    document.getElementById('image-modal').classList.add('hidden');
}

let isProcessing = false;

async function processNext() {
    if (isProcessing) return;
    const nextItem = pipeline.find(x => x.status === 'pending');
    if (!nextItem) return;

    isProcessing = true;
    nextItem.status = 'processing';
    renderPipeline();

    const formData = new FormData();
    formData.append('file', nextItem.file);
    const buyerCuiInput = document.getElementById('buyer-cui');
    if (buyerCuiInput && buyerCuiInput.value.trim() !== "") {
        formData.append('buyer_cui', buyerCuiInput.value.trim());
    }
    
    const processingMode = document.getElementById('processing-mode')?.value || 'bon';
    formData.append('processing_mode', processingMode);

    const baseUrl = document.getElementById('server-ip').value.replace(/\/$/, "");

    try {
        const response = await fetch(`${baseUrl}/upload`, { method: 'POST', headers: { 'Accept': 'application/json' }, body: formData });
        if (!response.ok) throw new Error('Network error');
        const data = await response.json();
        
        if (data.success) {
            nextItem.rawResponse = data;
            if (typeof renderReceipts === 'function') renderReceipts(data);
            if (typeof renderChitante === 'function') renderChitante(data);
        }

        if (data.success && data.accounting_data_array && data.accounting_data_array.length > 0) {
            // Daca avem un singur bon gasit, updatam randul curent
            if (data.accounting_data_array.length === 1) {
                nextItem.data = data.accounting_data_array[0];
                nextItem.data.suggestedAccount = suggestAccount(nextItem.data.companyName, nextItem.data.documentType, nextItem.data.suggestedAccount);
                nextItem.status = 'done';
            } else {
                // Daca avem mai multe, stergem randul vechi si cream N randuri noi
                pipeline = pipeline.filter(x => x.id !== nextItem.id);
                data.accounting_data_array.forEach((accData, idx) => {
                    const newId = nextItem.id + "_" + idx;
                    accData.suggestedAccount = suggestAccount(accData.companyName, accData.documentType, accData.suggestedAccount);
                    pipeline.push({
                        id: newId,
                        file: nextItem.file,
                        name: `${nextItem.name} (Bon ${idx + 1})`,
                        status: 'done',
                        data: accData,
                        url: nextItem.url,
                        rawResponse: data
                    });
                });
            }
        } else if (data.success && data.accounting_data) {
            // Compatibilitate backward
            nextItem.data = data.accounting_data;
            nextItem.data.suggestedAccount = suggestAccount(nextItem.data.companyName, nextItem.data.documentType, nextItem.data.suggestedAccount);
            nextItem.status = 'done';
        } else {
            nextItem.status = 'error';
        }
    } catch (e) {
        nextItem.status = 'error';
    }

    isProcessing = false;
    renderPipeline();
    processNext(); // loop to next item
}

// Export Excel Bulk
document.getElementById('export-bulk-btn').addEventListener('click', () => {
    const doneItems = pipeline.filter(x => x.status === 'done' && x.data);
    if (doneItems.length === 0) {
        alert("Nu ai documente procesate complet pentru a genera Excel-ul.");
        return;
    }

    let rows = [];

    if (templateHeaders && templateHeaders.length > 0) {
        // Varianta B: Template Personalizat
        const customMapping = {};
        document.querySelectorAll('.custom-mapping-select').forEach(select => {
            if (select.value) {
                customMapping[select.dataset.syskey] = select.value;
            }
        });

        rows = doneItems.map(item => {
            const d = item.data;
            const isChitanta = d.documentType === 'Chitanță de mână' || d.documentType === 'Chitanță POS';
            const row = {};
            // Initialize with empty strings for all template headers to maintain structure
            templateHeaders.forEach(th => row[th] = '');
            
            if (customMapping.filename) row[customMapping.filename] = item.name;
            if (customMapping.type) row[customMapping.type] = d.documentType || '';
            if (customMapping.series) row[customMapping.series] = d.documentSeries || '';
            if (customMapping.number) row[customMapping.number] = d.documentNumber || '';
            if (customMapping.date) row[customMapping.date] = d.documentDate || '';
            if (customMapping.cui) row[customMapping.cui] = d.cui || '';
            if (customMapping.company) row[customMapping.company] = d.companyName || '';
            
            if (isChitanta) {
                row['Sumă Plătită'] = d.totalAmount !== undefined ? d.totalAmount : '';
                if (customMapping.total) row[customMapping.total] = '';
                if (customMapping.base) row[customMapping.base] = '';
                if (customMapping.vat) row[customMapping.vat] = '';
                if (customMapping.vatPercentages) row[customMapping.vatPercentages] = '';
            } else {
                if (customMapping.total) row[customMapping.total] = d.totalAmount !== undefined ? d.totalAmount : '';
                if (customMapping.base) row[customMapping.base] = d.baseAmount !== undefined ? d.baseAmount : '';
                if (customMapping.vat) row[customMapping.vat] = d.vatAmount !== undefined ? d.vatAmount : '';
                if (customMapping.vatPercentages) row[customMapping.vatPercentages] = d.vatPercentages || '';
            }
            if (customMapping.account) row[customMapping.account] = d.suggestedAccount || '';
            
            return row;
        });

    } else {
        // Varianta A: Construire dupa header-ele configurate
        const mapping = {};
        document.querySelectorAll('.export-col').forEach(input => {
            mapping[input.dataset.key] = input.value;
        });

        rows = doneItems.map(item => {
            const d = item.data;
            const isChitanta = d.documentType === 'Chitanță de mână' || d.documentType === 'Chitanță POS';
            
            const totalHeader = isChitanta ? 'Sumă Plătită' : mapping.total;
            
            return {
                [mapping.filename]: item.name,
                [mapping.type]: d.documentType || '',
                [mapping.series]: d.documentSeries || '',
                [mapping.number]: d.documentNumber || '',
                [mapping.date]: d.documentDate || '',
                [mapping.cui]: d.cui || '',
                [mapping.company]: d.companyName || '',
                [totalHeader]: d.totalAmount !== undefined ? d.totalAmount : '',
                [mapping.base]: isChitanta ? '' : (d.baseAmount !== undefined ? d.baseAmount : ''),
                [mapping.vat]: isChitanta ? '' : (d.vatAmount !== undefined ? d.vatAmount : ''),
                [mapping.vatPercentages]: isChitanta ? '' : (d.vatPercentages || ''),
                [mapping.account]: d.suggestedAccount || ''
            };
        });
    }

    const worksheet = XLSX.utils.json_to_sheet(rows);
    const workbook = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(workbook, worksheet, "Export OCR");
    
    // Genereaza numele fisierului Excel
    const d = new Date();
    const dateStr = `${d.getFullYear()}-${d.getMonth()+1}-${d.getDate()}`;
    XLSX.writeFile(workbook, `export_contabilitate_${dateStr}.xlsx`);
});

// Init
renderRules();

// Salvare Setari Server (IP si CUI)
const serverIpInput = document.getElementById('server-ip');
const buyerCuiInput = document.getElementById('buyer-cui');

if (localStorage.getItem('serverIp')) {
    serverIpInput.value = localStorage.getItem('serverIp');
}
if (localStorage.getItem('buyerCui')) {
    buyerCuiInput.value = localStorage.getItem('buyerCui');
}

serverIpInput.addEventListener('input', (e) => {
    localStorage.setItem('serverIp', e.target.value);
    checkConnection();
});
buyerCuiInput.addEventListener('input', (e) => {
    localStorage.setItem('buyerCui', e.target.value);
});

// Verificare Conexiune (Ping)
const statusIndicator = document.getElementById('connection-status');
async function checkConnection() {
    if (isProcessing) return; // Serverul ruleaza OCR, nu trimitem ping ca sa nu luam timeout fals
    
    const ip = serverIpInput.value.trim();
    if (!ip) {
        statusIndicator.textContent = 'Deconectat';
        statusIndicator.style.background = 'var(--danger)';
        return;
    }
    
    try {
        // AbortController pentru timeout (in caz ca fetch-ul ramane "agatat")
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 2000);
        
        const res = await fetch(`${ip}/ping`, { method: 'GET', signal: controller.signal });
        clearTimeout(timeoutId);
        
        if (res.ok) {
            statusIndicator.textContent = 'Conectat';
            statusIndicator.style.background = 'var(--valid)';
        } else {
            throw new Error('Not OK');
        }
    } catch (e) {
        statusIndicator.textContent = 'Deconectat';
        statusIndicator.style.background = 'var(--danger)';
    }
}
setInterval(checkConnection, 3000);
checkConnection();

// --- Logica Varianta B: Incarcare Sablon Excel ---
let templateHeaders = [];
const templateUpload = document.getElementById('template-upload');
const templateMappingUI = document.getElementById('template-mapping-ui');
const mappingContainer = document.getElementById('mapping-container');

const systemFields = [
    { key: 'filename', label: 'Nume Fișier Original' },
    { key: 'type', label: 'Tip Document' },
    { key: 'cui', label: 'CUI Furnizor' },
    { key: 'company', label: 'Denumire Furnizor' },
    { key: 'series', label: 'Serie Document' },
    { key: 'number', label: 'Număr Document' },
    { key: 'date', label: 'Dată Document' },
    { key: 'total', label: 'Total (cu TVA)' },
    { key: 'base', label: 'Bază (fără TVA)' },
    { key: 'vat', label: 'TVA Valoric' },
    { key: 'vatPercentages', label: 'Cote TVA (%)' },
    { key: 'account', label: 'Cont Sugerat' }
];

if(templateUpload) {
    templateUpload.addEventListener('change', (e) => {
        const file = e.target.files[0];
        if (!file) return;

        const reader = new FileReader();
        reader.onload = function(event) {
            const data = new Uint8Array(event.target.result);
            const workbook = XLSX.read(data, {type: 'array'});
            const firstSheetName = workbook.SheetNames[0];
            const worksheet = workbook.Sheets[firstSheetName];
            
            // Daca foaia e complet goala
            if(!worksheet['!ref']) {
                alert('Fișierul Excel încărcat pare a fi gol (nu s-a detectat cap de tabel).');
                return;
            }
            
            // Extrage prima linie (row 1)
            const range = XLSX.utils.decode_range(worksheet['!ref']);
            templateHeaders = [];
            for (let C = range.s.c; C <= range.e.c; ++C) {
                const cellAddress = {c: C, r: range.s.r};
                const cellRef = XLSX.utils.encode_cell(cellAddress);
                const cell = worksheet[cellRef];
                let header = cell ? cell.v : `Coloana ${C+1}`;
                templateHeaders.push(header);
            }
            
            // Genereaza UI pentru Mapare
            mappingContainer.innerHTML = '';
            systemFields.forEach(field => {
                // Incercam sa ghicim o mapare automata daca numele seamana (simplificat)
                let options = `<option value="">-- Ignoră (Rămâne gol) --</option>`;
                templateHeaders.forEach(th => {
                    const isMatch = th.toString().toLowerCase().includes(field.label.split(' ')[0].toLowerCase());
                    options += `<option value="${th}" ${isMatch ? 'selected' : ''}>${th}</option>`;
                });
                
                mappingContainer.innerHTML += `
                    <div>
                        <label>${field.label}:</label>
                        <select class="custom-mapping-select" data-syskey="${field.key}" style="width: 100%; padding: 8px; background: var(--bg-main); border: 1px solid var(--border); color: white; border-radius: 4px;">
                            ${options}
                        </select>
                    </div>
                `;
            });
            
            templateMappingUI.classList.remove('hidden');
        };
        reader.readAsArrayBuffer(file);
    });
}
