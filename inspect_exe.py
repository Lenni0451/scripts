import sys
import struct
import pefile
import warnings
from PyQt6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, 
    QHBoxLayout, QLabel, QFrame, QFormLayout, QFileDialog, QMessageBox
)
from PyQt6.QtGui import QPixmap
from PyQt6.QtCore import Qt, pyqtSignal

class ClickableLabel(QLabel):
    clicked = pyqtSignal()
    
    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit()
        super().mousePressEvent(event)

try:
    from cryptography.hazmat.primitives.serialization import pkcs7
    from cryptography.x509.oid import NameOID
    HAVE_CRYPTO = True
except ImportError:
    HAVE_CRYPTO = False

QSS = """
QWidget#MainWindow {
    background-color: #1e1e2e;
}
QLabel {
    color: #cdd6f4;
    font-family: "Segoe UI", "Helvetica Neue", sans-serif;
    font-size: 14px;
}
QFrame#Card {
    background-color: #313244;
    border-radius: 12px;
}
QLabel#Title {
    font-size: 24px;
    font-weight: bold;
    color: #b4befe;
}
QLabel#SectionHeader {
    font-size: 16px;
    font-weight: bold;
    color: #89b4fa;
    margin-bottom: 5px;
}
QLabel#Value {
    color: #a6e3a1;
    font-weight: 500;
}
QLabel#Error {
    color: #f38ba8;
    font-weight: bold;
}
"""

def extract_largest_icon(pe):
    if not hasattr(pe, 'DIRECTORY_ENTRY_RESOURCE'):
        return None
        
    rt_icon_id = pefile.RESOURCE_TYPE.get('RT_ICON', 3)
    
    icon_entries = []
    for entry in pe.DIRECTORY_ENTRY_RESOURCE.entries:
        if entry.struct.Id == rt_icon_id:
            for icon_entry in entry.directory.entries:
                for resource in icon_entry.directory.entries:
                    offset = resource.data.struct.OffsetToData
                    size = resource.data.struct.Size
                    data = pe.get_memory_mapped_image()[offset:offset+size]
                    icon_entries.append((size, data))
                    
    if not icon_entries:
        return None
        
    icon_entries.sort(key=lambda x: x[0], reverse=True)
    size, data = icon_entries[0]
    
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        return data
        
    ico_data = bytearray()
    ico_data.extend(struct.pack('<HHH', 0, 1, 1))
    
    if len(data) >= 40:
        width = struct.unpack('<I', data[4:8])[0]
        height = struct.unpack('<I', data[8:12])[0] // 2
        
        bWidth = width if width < 256 else 0
        bHeight = height if height < 256 else 0
        wPlanes = struct.unpack('<H', data[12:14])[0]
        wBitCount = struct.unpack('<H', data[14:16])[0]
        
        ico_data.extend(struct.pack('<BBBBHHII', bWidth, bHeight, 0, 0, wPlanes, wBitCount, size, 22))
        ico_data.extend(data)
        return bytes(ico_data)
        
    return None

def get_author(pe):
    if hasattr(pe, 'FileInfo'):
        for file_info in pe.FileInfo:
            for entry in file_info:
                if hasattr(entry, 'StringTable'):
                    for st in entry.StringTable:
                        for key, val in st.entries.items():
                            if key == b'CompanyName':
                                return val.decode('utf-8', 'ignore')
    return "Not available"

def get_signing_info(file_path, pe):
    try:
        idx = pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_SECURITY']
        if idx >= len(pe.OPTIONAL_HEADER.DATA_DIRECTORY):
            return "Not signed", None
            
        security_dir = pe.OPTIONAL_HEADER.DATA_DIRECTORY[idx]
        if security_dir.VirtualAddress == 0 or security_dir.Size == 0:
            return "Not signed", None
            
        offset = security_dir.VirtualAddress
        size = security_dir.Size
        
        with open(file_path, "rb") as f:
            f.seek(offset)
            cert_data = f.read(size)
            
        if len(cert_data) < 8:
            return "Invalid signature data", None
            
        dwLength, wRevision, wCertificateType = struct.unpack('<IHH', cert_data[:8])
        pkcs7_data = cert_data[8:dwLength]
        
        status = f"Signed (Signature Size: {security_dir.Size} bytes)"
        details = []
        
        if HAVE_CRYPTO:
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    p7 = pkcs7.load_der_pkcs7_certificates(pkcs7_data)
                
                signers = []
                for cert in p7:
                    try:
                        cn = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
                    except IndexError:
                        cn = cert.subject.rfc4514_string()
                        
                    # Filter out obvious CAs to find the main signer
                    if "CA" not in cn and "Root" not in cn and "Time Stamping" not in cn:
                        signers.append(cn)
                    
                    details.append(f"• {cn}")
                
                if signers:
                    status = f"Signed by {', '.join(set(signers))}"
                    
            except Exception as e:
                details.append(f"[PKCS7 Parse Error]: {e}")
        else:
            details.append("(Install 'cryptography' for certificate parsing)")
            
        return status, "\n".join(details)
        
    except Exception as e:
        return f"Error reading signature: {e}", None

def get_cpu_arch(pe):
    machine = pe.FILE_HEADER.Machine
    machine_types = {
        0x014c: '32-bit x86 (I386)',
        0x8664: '64-bit x64 (AMD64)',
        0xaa64: 'ARM64',
        0x01c0: 'ARM',
        0x0200: 'IA64',
    }
    return machine_types.get(machine, f"Unknown (0x{machine:04x})")

class ExeInspector(QWidget):
    def __init__(self, file_path):
        super().__init__()
        self.setObjectName("MainWindow")
        self.setWindowTitle("EXE Inspector")
        self.setStyleSheet(QSS)
        
        # Main layout with margins
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(20, 20, 20, 20)
        main_layout.setSpacing(15)
        main_layout.setSizeConstraint(QVBoxLayout.SizeConstraint.SetFixedSize)
        
        try:
            pe = pefile.PE(file_path)
            self.display_metadata(file_path, pe, main_layout)
        except Exception as e:
            error_label = QLabel(f"Error reading PE file:\n{str(e)}")
            error_label.setObjectName("Error")
            error_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
            main_layout.addWidget(error_label)
            
    def create_card(self, title_text, content_layout):
        card = QFrame()
        card.setObjectName("Card")
        
        layout = QVBoxLayout(card)
        layout.setContentsMargins(15, 15, 15, 15)
        layout.setSpacing(10)
        
        header = QLabel(title_text)
        header.setObjectName("SectionHeader")
        layout.addWidget(header)
        
        layout.addLayout(content_layout)
        return card
        
    def display_metadata(self, file_path, pe, layout):
        import os
        
        # Top Header Area (Icon + File Name)
        header_layout = QHBoxLayout()
        icon_label = ClickableLabel()
        icon_data = extract_largest_icon(pe)
        
        if icon_data:
            pixmap = QPixmap()
            pixmap.loadFromData(icon_data)
            if not pixmap.isNull():
                icon_label.setPixmap(pixmap.scaled(72, 72, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
                icon_label.setCursor(Qt.CursorShape.PointingHandCursor)
                icon_label.setToolTip("Click to export icon")
                icon_label.clicked.connect(lambda: self.export_icon(icon_data))
            else:
                icon_label.setText("[Icon Error]")
        else:
            icon_label.setText("[No Icon]")
            
        header_layout.addWidget(icon_label)
        
        title_layout = QVBoxLayout()
        filename_label = QLabel(os.path.basename(file_path))
        filename_label.setObjectName("Title")
        title_layout.addWidget(filename_label)
        
        size_label = QLabel(f"Size: {os.path.getsize(file_path):,} bytes")
        title_layout.addWidget(size_label)
        
        header_layout.addLayout(title_layout)
        header_layout.addStretch()
        layout.addLayout(header_layout)
        
        # General Info Card
        form_layout = QFormLayout()
        form_layout.setLabelAlignment(Qt.AlignmentFlag.AlignRight)
        form_layout.setFormAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)
        
        arch_val = QLabel(get_cpu_arch(pe))
        arch_val.setObjectName("Value")
        form_layout.addRow("Architecture:", arch_val)
        
        author_val = QLabel(get_author(pe))
        author_val.setObjectName("Value")
        form_layout.addRow("Author:", author_val)
        
        layout.addWidget(self.create_card("General Information", form_layout))
        
        # Signature Info Card
        sig_status, sig_details = get_signing_info(file_path, pe)
        
        sig_layout = QVBoxLayout()
        status_lbl = QLabel(sig_status)
        status_lbl.setObjectName("Value")
        sig_layout.addWidget(status_lbl)
        
        if sig_details:
            details_lbl = QLabel(sig_details)
            details_lbl.setWordWrap(True)
            details_lbl.setStyleSheet("color: #bac2de; font-size: 13px; margin-top: 5px;")
            sig_layout.addWidget(details_lbl)
            
        layout.addWidget(self.create_card("Digital Signature", sig_layout))
        
        layout.addStretch()

    def export_icon(self, icon_data):
        import subprocess
        try:
            # Try to use the native system file chooser via zenity on Linux
            result = subprocess.run([
                "zenity", "--file-selection", "--save", 
                "--confirm-overwrite", "--filename=icon.ico",
                "--title=Save Icon", "--file-filter=Icon Files | *.ico"
            ], capture_output=True, text=True)
            
            if result.returncode == 0:
                file_path = result.stdout.strip()
                if file_path:
                    with open(file_path, "wb") as f:
                        f.write(icon_data)
        except FileNotFoundError:
            # Fallback to Qt's internal dialog if zenity is somehow not available
            file_path, _ = QFileDialog.getSaveFileName(self, "Save Icon", "icon.ico", "Icon Files (*.ico);;All Files (*)")
            if file_path:
                try:
                    with open(file_path, "wb") as f:
                        f.write(icon_data)
                except Exception as e:
                    QMessageBox.critical(self, "Error", f"Failed to save icon:\n{e}")
        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to save icon:\n{e}")

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <path_to_exe>")
        sys.exit(1)
        
    app = QApplication(sys.argv)
    app.setStyle("Fusion") # Better base style for dark theme
    window = ExeInspector(sys.argv[1])
    window.show()
    sys.exit(app.exec())

if __name__ == "__main__":
    main()
